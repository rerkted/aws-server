import os
import json
import uuid
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

from .layers.request_analysis import analyze_request
from .layers.state_manager import StateManager
from .layers.planner import generate_plan
from .layers.executor import Executor
from .models import ExecutionPlan, InfrastructureState

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# In-memory session store: session_id -> {websocket, pending_plan, state}
sessions: dict[str, dict] = {}

state_manager = StateManager(region=AWS_REGION)
executor = Executor(region=AWS_REGION)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Infrastructure AI Agent starting up")
    yield
    logger.info("Infrastructure AI Agent shutting down")


app = FastAPI(title="Infrastructure AI Agent", lifespan=lifespan)


async def ws_send(websocket: WebSocket, msg_type: str, content):
    await websocket.send_text(json.dumps({"type": msg_type, "content": content}))


@app.get("/health")
def health():
    return "OK"


@app.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    await websocket.accept()
    sessions[session_id] = {"websocket": websocket, "pending_plan": None, "state": None}
    logger.info(f"Session {session_id} connected")

    try:
        while True:
            raw = await websocket.receive_text()
            data = json.loads(raw)
            message = data.get("message", "").strip()

            if not message:
                continue

            if not ANTHROPIC_API_KEY:
                await ws_send(websocket, "error", "ANTHROPIC_API_KEY not configured.")
                continue

            # Handle approval/rejection responses
            if data.get("approve") is not None:
                await _handle_approval(websocket, session_id, data["approve"])
                continue

            try:
                # Layer 1: Analyze request
                await ws_send(websocket, "thinking", "Analyzing your request...")
                intent = await analyze_request(message, ANTHROPIC_API_KEY)
                logger.info(f"[{session_id}] Intent: {intent.action} | {intent.description}")

                # Layer 2: Discover current state
                await ws_send(websocket, "thinking", "Scanning AWS infrastructure...")
                state = state_manager.discover()
                sessions[session_id]["state"] = state
                await ws_send(websocket, "state", state.model_dump())

                # Layer 3: Generate plan
                await ws_send(websocket, "thinking", "Generating execution plan...")
                plan = await generate_plan(intent, state, ANTHROPIC_API_KEY)
                logger.info(f"[{session_id}] Plan: {plan.risk_level} | approval={plan.requires_approval}")

                if plan.requires_approval:
                    sessions[session_id]["pending_plan"] = plan
                    await ws_send(websocket, "plan", plan.model_dump())
                else:
                    # Read-only: execute immediately
                    result = executor.execute(plan, state)
                    await ws_send(websocket, "result", result.model_dump())

            except json.JSONDecodeError as e:
                logger.error(f"[{session_id}] JSON parse error: {e}")
                await ws_send(websocket, "error", "Failed to parse LLM response. Please try again.")
            except Exception as e:
                logger.error(f"[{session_id}] Error: {e}", exc_info=True)
                await ws_send(websocket, "error", f"Agent error: {str(e)}")

    except WebSocketDisconnect:
        sessions.pop(session_id, None)
        logger.info(f"Session {session_id} disconnected")


async def _handle_approval(websocket: WebSocket, session_id: str, approved: bool):
    session = sessions.get(session_id, {})
    plan: ExecutionPlan | None = session.get("pending_plan")
    state: InfrastructureState | None = session.get("state")

    if not plan:
        await ws_send(websocket, "error", "No pending plan to approve.")
        return

    sessions[session_id]["pending_plan"] = None

    if not approved:
        await ws_send(websocket, "result", {
            "success": False,
            "message": "Plan rejected. No changes made.",
            "details": [],
            "terraform_snippet": None,
        })
        return

    await ws_send(websocket, "thinking", "Executing plan...")
    try:
        result = executor.execute(plan, state)
        await ws_send(websocket, "result", result.model_dump())
    except Exception as e:
        logger.error(f"Execution error: {e}", exc_info=True)
        await ws_send(websocket, "error", f"Execution failed: {str(e)}")


# Serve static files (chat UI)
app.mount("/static", StaticFiles(directory="/app/static"), name="static")


@app.get("/")
def index():
    return FileResponse("/app/static/index.html")
