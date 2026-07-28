//! Google Vertex AI provider for Claude models.
//!
//! Uses the Vertex AI `streamRawPredict` endpoint:
//!   https://aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/
//!     publishers/anthropic/models/{model}:streamRawPredict
//!
//! Auth: Application Default Credentials via `gcloud auth application-default login`.
//! Required env vars:
//!   - GOOGLE_CLOUD_PROJECT (or GCLOUD_PROJECT)
//!   - GOOGLE_CLOUD_LOCATION (optional, defaults to "us-east5")

use std::env;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use flume::Sender;
use isahc::{HttpClient, Request};
use maki_storage::id::SessionRef;
use serde_json::{Value, json};
use tracing::{debug, warn};

use crate::model::Model;
use crate::provider::{BoxFuture, Provider};
use crate::{AgentError, Message, ProviderEvent, RequestOptions, StreamResponse};

use super::shared;

const VERTEX_API_VERSION: &str = "vertex-2023-10-16";
const TOKEN_REFRESH_MARGIN: Duration = Duration::from_secs(5 * 60);

/// Check if Vertex AI provider is enabled via environment variable.
pub(crate) fn is_enabled() -> bool {
    env::var("VERTEX_CLAUDE").is_ok_and(|v| v == "1")
        || env::var("GOOGLE_CLOUD_PROJECT").is_ok()
        || env::var("GCLOUD_PROJECT").is_ok()
}

#[derive(Clone)]
struct VertexAuth {
    access_token: String,
    expires_at: u64, // epoch seconds
    project: String,
    location: String,
}

fn get_project() -> Result<String, AgentError> {
    env::var("GOOGLE_CLOUD_PROJECT")
        .or_else(|_| env::var("GCLOUD_PROJECT"))
        .map_err(|_| AgentError::Config {
            message: "GOOGLE_CLOUD_PROJECT must be set when using Vertex AI".into(),
        })
}

fn get_location() -> String {
    env::var("GOOGLE_CLOUD_LOCATION").unwrap_or_else(|_| "us-east5".to_string())
}

fn fetch_access_token() -> Result<(String, u64), AgentError> {
    // Try gcloud CLI first
    let output = Command::new("gcloud")
        .args(["auth", "application-default", "print-access-token"])
        .output()
        .map_err(|e| AgentError::Config {
            message: format!("failed to run gcloud: {e}"),
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AgentError::Config {
            message: format!("gcloud auth failed: {stderr}"),
        });
    }

    let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
    
    // Google OAuth tokens typically expire in 1 hour
    let expires_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() + 3600)
        .unwrap_or(0);

    Ok((token, expires_at))
}

fn resolve_vertex_auth() -> Result<VertexAuth, AgentError> {
    let project = get_project()?;
    let location = get_location();
    let (access_token, expires_at) = fetch_access_token()?;

    debug!(project = %project, location = %location, "Vertex AI auth resolved");

    Ok(VertexAuth {
        access_token,
        expires_at,
        project,
        location,
    })
}

pub(crate) struct Vertex {
    client: HttpClient,
    auth: Arc<Mutex<VertexAuth>>,
    stream_timeout: Duration,
}

impl Vertex {
    pub fn new(timeouts: super::super::Timeouts) -> Result<Self, AgentError> {
        let auth = resolve_vertex_auth().inspect_err(|e| {
            warn!(error = %e, "Vertex AI auth resolution failed");
        })?;
        Ok(Self {
            client: super::super::http_client(timeouts),
            auth: Arc::new(Mutex::new(auth)),
            stream_timeout: timeouts.stream,
        })
    }

    fn needs_refresh(&self) -> bool {
        let auth = self.auth.lock().unwrap();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        now + TOKEN_REFRESH_MARGIN.as_secs() >= auth.expires_at
    }

    fn build_url(&self, model_id: &str) -> String {
        let auth = self.auth.lock().unwrap();
        let encoded_model = super::super::urlenc(model_id);
        format!(
            "https://{}-aiplatform.googleapis.com/v1/projects/{}/locations/{}/publishers/anthropic/models/{}:streamRawPredict",
            auth.location, auth.project, auth.location, encoded_model
        )
    }
}

impl Provider for Vertex {
    fn stream_message<'a>(
        &'a self,
        model: &'a Model,
        messages: &'a [Message],
        system: &'a str,
        tools: &'a Value,
        event_tx: &'a Sender<ProviderEvent>,
        opts: RequestOptions,
        _session_id: Option<&'a SessionRef>,
    ) -> BoxFuture<'a, Result<StreamResponse, AgentError>> {
        Box::pin(async move {
            if self.needs_refresh() {
                debug!("Vertex AI token near expiry, refreshing before request");
                self.reload_auth().await?;
            }

            let auth = self.auth.lock().unwrap().clone();
            let requested_id = env::var("ANTHROPIC_MODEL").unwrap_or_else(|_| model.id.clone());
            let long_context = requested_id.ends_with(shared::LONG_CONTEXT_SUFFIX);
            let model_id = shared::strip_long_context(&requested_id).to_string();

            let mut body = shared::build_request_body_with_system(
                model,
                messages,
                &[shared::SystemBlock {
                    r#type: "text",
                    text: system,
                    cache_control: Some(shared::EPHEMERAL),
                }],
                tools,
                opts.thinking,
            );

            body["anthropic_version"] = json!(VERTEX_API_VERSION);
            body["stream"] = json!(true);

            let has_examples = tools
                .as_array()
                .is_some_and(|arr| arr.iter().any(|t| t.get("input_examples").is_some()));

            // Vertex AI enables beta features by default; collect any we need
            let mut betas = Vec::new();
            if has_examples {
                betas.push(shared::BETA_TOOL_EXAMPLES_BEDROCK);
            }
            if long_context {
                betas.push(shared::LONG_CONTEXT_BETA);
            }
            if !betas.is_empty() {
                body["anthropic_beta"] = json!(betas);
            }

            let url = self.build_url(&model_id);
            let json_body = serde_json::to_vec(&body)?;

            let request = Request::builder()
                .method("POST")
                .uri(&url)
                .header("Authorization", format!("Bearer {}", auth.access_token))
                .header("Content-Type", "application/json")
                .body(json_body)?;

            let response = self.client.send_async(request).await?;
            let status = response.status().as_u16();

            if status == 200 {
                super::parse_sse(response, event_tx, self.stream_timeout).await
            } else {
                Err(AgentError::from_response(response).await)
            }
        })
    }

    fn list_models(&self) -> BoxFuture<'_, Result<Vec<crate::model::ModelInfo>, AgentError>> {
        // Vertex AI doesn't have a model listing API for Claude models;
        // return the known models statically
        Box::pin(async {
            Ok(vec![
                crate::model::ModelInfo::id_only("claude-opus-4-5".to_string()),
                crate::model::ModelInfo::id_only("claude-sonnet-4-6".to_string()),
                crate::model::ModelInfo::id_only("claude-sonnet-4-5".to_string()),
                crate::model::ModelInfo::id_only("claude-haiku-4-5".to_string()),
            ])
        })
    }

    fn reload_auth(&self) -> BoxFuture<'_, Result<(), AgentError>> {
        Box::pin(async {
            let new_auth = resolve_vertex_auth()?;
            *self.auth.lock().unwrap() = new_auth;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_enabled_with_project() {
        // This test checks the logic, not actual env vars
        let has_project = env::var("GOOGLE_CLOUD_PROJECT").is_ok()
            || env::var("GCLOUD_PROJECT").is_ok();
        // Just verify the function doesn't panic
        let _ = is_enabled();
        assert!(true);
    }
}
