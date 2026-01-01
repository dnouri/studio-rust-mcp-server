use crate::error::Result;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::{
    extract::{Query, State},
    Json,
};
use color_eyre::eyre::{Error, OptionExt};
use rmcp::{
    handler::server::tool::Parameters,
    model::{
        CallToolResult, Content, Implementation, ProtocolVersion, ServerCapabilities, ServerInfo,
    },
    schemars, tool, tool_handler, tool_router, ErrorData, ServerHandler,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::sync::Arc;
use tokio::sync::oneshot::Receiver;
use tokio::sync::{mpsc, watch, Mutex};
use tokio::time::Duration;
use uuid::Uuid;

pub const STUDIO_PLUGIN_PORT: u16 = 44755;
const LONG_POLL_DURATION: Duration = Duration::from_secs(15);

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct ToolArguments {
    args: ToolArgumentValues,
    id: Option<Uuid>,
    #[serde(default)]
    context: Option<String>, // Target context: "edit", "server", "client", "any"
}

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct RunCommandResponse {
    response: String,
    id: Uuid,
    #[serde(default)]
    context: Option<String>, // Responding context
}

pub struct AppState {
    process_queue: VecDeque<ToolArguments>,
    output_map: HashMap<Uuid, mpsc::UnboundedSender<Result<RunCommandResponse>>>,
    waiter: watch::Receiver<()>,
    trigger: watch::Sender<()>,
}
pub type PackedState = Arc<Mutex<AppState>>;

impl AppState {
    pub fn new() -> Self {
        let (trigger, waiter) = watch::channel(());
        Self {
            process_queue: VecDeque::new(),
            output_map: HashMap::new(),
            waiter,
            trigger,
        }
    }
}

impl ToolArguments {
    fn new(args: ToolArgumentValues, context: Option<String>) -> (Self, Uuid) {
        Self {
            args,
            id: None,
            context,
        }
        .with_id()
    }
    fn with_id(self) -> (Self, Uuid) {
        let id = Uuid::new_v4();
        (
            Self {
                args: self.args,
                id: Some(id),
                context: self.context,
            },
            id,
        )
    }
}
#[derive(Clone)]
pub struct RBXStudioServer {
    state: PackedState,
    tool_router: rmcp::handler::server::tool::ToolRouter<Self>,
}

#[tool_handler]
impl ServerHandler for RBXStudioServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            protocol_version: ProtocolVersion::V_2025_03_26,
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            server_info: Implementation::from_build_env(),
            instructions: Some(
                "Use run_code to query data from Roblox Studio place or to change it. Use context parameter to target: 'edit' (default), 'server' (during play), or 'any'."
                    .to_string(),
            ),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct RunCode {
    #[schemars(description = "Code to run")]
    command: String,
}
#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct InsertModel {
    #[schemars(description = "Query to search for the model")]
    query: String,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
enum ToolArgumentValues {
    RunCode(RunCode),
    InsertModel(InsertModel),
}
#[tool_router]
impl RBXStudioServer {
    pub fn new(state: PackedState) -> Self {
        Self {
            state,
            tool_router: Self::tool_router(),
        }
    }

    #[tool(
        description = "Runs a command in Roblox Studio and returns the printed output. Can be used to both make changes and retrieve information"
    )]
    async fn run_code(
        &self,
        Parameters(args): Parameters<RunCode>,
    ) -> Result<CallToolResult, ErrorData> {
        // Default to "any" context - auto-detect available plugin
        self.generic_tool_run(ToolArgumentValues::RunCode(args), Some("any".to_string()))
            .await
    }

    #[tool(
        description = "Inserts a model from the Roblox marketplace into the workspace. Returns the inserted model name."
    )]
    async fn insert_model(
        &self,
        Parameters(args): Parameters<InsertModel>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(
            ToolArgumentValues::InsertModel(args),
            Some("any".to_string()),
        )
        .await
    }

    async fn generic_tool_run(
        &self,
        args: ToolArgumentValues,
        context: Option<String>,
    ) -> Result<CallToolResult, ErrorData> {
        let (command, id) = ToolArguments::new(args, context);
        tracing::debug!("Running command: {:?}", command);
        let (tx, mut rx) = mpsc::unbounded_channel::<Result<RunCommandResponse>>();
        let trigger = {
            let mut state = self.state.lock().await;
            state.process_queue.push_back(command);
            state.output_map.insert(id, tx);
            state.trigger.clone()
        };
        trigger
            .send(())
            .map_err(|e| ErrorData::internal_error(format!("Unable to trigger send {e}"), None))?;
        let result = rx
            .recv()
            .await
            .ok_or(ErrorData::internal_error("Couldn't receive response", None))?;
        {
            let mut state = self.state.lock().await;
            state.output_map.remove_entry(&id);
        }
        tracing::debug!("Sending to MCP: {result:?}");
        match result {
            Ok(result) => {
                let prefix = result
                    .context
                    .map(|c| format!("[{}] ", c))
                    .unwrap_or_default();
                Ok(CallToolResult::success(vec![Content::text(format!(
                    "{}{}",
                    prefix, result.response
                ))]))
            }
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err.to_string())])),
        }
    }
}

/// Query parameters for the request handler
#[derive(Debug, Deserialize)]
pub struct RequestQuery {
    #[serde(default)]
    context: Option<String>,
}

/// Check if a request matches a plugin's context
fn context_matches(request_context: &Option<String>, plugin_context: &Option<String>) -> bool {
    match (request_context.as_deref(), plugin_context.as_deref()) {
        // "any" matches everything
        (Some("any"), _) => true,
        // No context specified in request defaults to "edit"
        (None, Some("edit")) => true,
        (None, None) => true,
        // Exact match
        (Some(req), Some(plug)) => req == plug,
        // Request has context but plugin didn't specify - treat plugin as "edit"
        (Some(req), None) => req == "edit",
        // Request has no context, plugin has non-edit context - no match
        (None, Some(_)) => false,
    }
}

pub async fn request_handler(
    State(state): State<PackedState>,
    Query(query): Query<RequestQuery>,
) -> Result<impl IntoResponse> {
    let plugin_context = query.context;
    tracing::debug!("Plugin polling with context: {:?}", plugin_context);

    let timeout = tokio::time::timeout(LONG_POLL_DURATION, async {
        loop {
            let mut waiter = {
                let mut state = state.lock().await;
                // Find a request that matches this plugin's context
                let matching_idx = state
                    .process_queue
                    .iter()
                    .position(|task| context_matches(&task.context, &plugin_context));

                if let Some(idx) = matching_idx {
                    let task = state.process_queue.remove(idx).unwrap();
                    tracing::debug!(
                        "Sending task to plugin context {:?}: {:?}",
                        plugin_context,
                        task
                    );
                    return Ok::<ToolArguments, Error>(task);
                }
                state.waiter.clone()
            };
            waiter.changed().await?
        }
    })
    .await;
    match timeout {
        Ok(result) => Ok(Json(result?).into_response()),
        _ => Ok((StatusCode::LOCKED, String::new()).into_response()),
    }
}

pub async fn response_handler(
    State(state): State<PackedState>,
    Json(payload): Json<RunCommandResponse>,
) -> Result<impl IntoResponse> {
    tracing::debug!("Received reply from studio {:?}", payload);
    let mut state = state.lock().await;
    let tx = state
        .output_map
        .remove(&payload.id)
        .ok_or_eyre("Unknown ID")?;
    Ok(tx.send(Ok(payload))?)
}

pub async fn proxy_handler(
    State(state): State<PackedState>,
    Json(command): Json<ToolArguments>,
) -> Result<impl IntoResponse> {
    let id = command.id.ok_or_eyre("Got proxy command with no id")?;
    tracing::debug!("Received request to proxy {:?}", command);
    let (tx, mut rx) = mpsc::unbounded_channel();
    {
        let mut state = state.lock().await;
        state.process_queue.push_back(command);
        state.output_map.insert(id, tx);
        state.trigger.send(()).ok();
    }
    let response = rx.recv().await.ok_or_eyre("Couldn't receive response")??;
    {
        let mut state = state.lock().await;
        state.output_map.remove_entry(&id);
    }
    tracing::debug!("Sending back response: {:?}", response);
    Ok(Json(response))
}

pub async fn dud_proxy_loop(state: PackedState, exit: Receiver<()>) {
    let client = reqwest::Client::new();

    let mut waiter = { state.lock().await.waiter.clone() };
    while exit.is_empty() {
        let entry = { state.lock().await.process_queue.pop_front() };
        if let Some(entry) = entry {
            let res = client
                .post(format!("http://127.0.0.1:{STUDIO_PLUGIN_PORT}/proxy"))
                .json(&entry)
                .send()
                .await;
            if let Ok(res) = res {
                let tx = {
                    state
                        .lock()
                        .await
                        .output_map
                        .remove(&entry.id.unwrap())
                        .unwrap()
                };
                let res = res.json::<RunCommandResponse>().await.map_err(Into::into);
                tx.send(res).unwrap();
            } else {
                tracing::error!("Failed to proxy: {res:?}");
            };
        } else {
            waiter.changed().await.unwrap();
        }
    }
}
