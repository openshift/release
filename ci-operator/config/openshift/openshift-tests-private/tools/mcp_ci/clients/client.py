#!/usr/bin/env python
"""
MCP client that connects to an MCP server, loads tools, and runs a chat loop using any LLM that you likes.
"""

import asyncio
import os
import sys
import json

from dotenv import load_dotenv

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from langchain_mcp_adapters.tools import load_mcp_tools
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.prebuilt import create_react_agent
from langchain_openai import ChatOpenAI

load_dotenv()

# Custom JSON encoder for objects with 'content' attribute
class CustomEncoder(json.JSONEncoder):
    def default(self, o):
        if hasattr(o, "content"):
            return {"type": o.__class__.__name__, "content": o.content}
        return super().default(o)

if not os.getenv("SSL_CERT_FILE"):
    print("SSL_CERT_FILE is not set")
    sys.exit(1)

llm = ChatOpenAI(model=os.getenv("MODEL"),
                base_url=os.getenv("BASE_URL"),
                api_key=os.getenv("API_KET"),
                temperature=0.7,
                streaming=False
            )

# Require server script path as command-line argument
if len(sys.argv) < 2:
    print("Usage: python clients/client.py servers/ci_server.py")
    sys.exit(1)
server_script = sys.argv[1]

server_params = StdioServerParameters(
    command="uv",  # Using uv to run the server
    args=["run", server_script],  # Server with completion support
)

# Global holder for the active MCP session (used by tool adapter)
mcp_client = None

# Main async function: connect, load tools, create agent, run chat loop
async def run_agent():
    global mcp_client
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            mcp_client = type("MCPClientHolder", (), {"session": session})()
            tools = await load_mcp_tools(session)
            checkpointer = InMemorySaver()
            agent = create_react_agent(llm, tools, checkpointer=checkpointer)
            thread_id = 12000

            print("MCP Client Started!")
            print(" - Type 'quit' to exit.")
            print(" - Type 'clear' to clear previous conversation and start a new one (AI can understand context in one conversation).")
            while True:
                query = input("\\nQuery: ").strip()
                if query.lower() == "quit":
                    break
                if query.lower() == "clear":
                    thread_id += thread_id
                config = {"configurable": {"thread_id": str(thread_id)}}
                    
                # Send user query to agent and print formatted response
                response = await agent.ainvoke({"messages": query}, config)
                
                try:
                    formatted = json.dumps(response, indent=2, cls=CustomEncoder)
                except Exception:
                    formatted = str(response)
                print("\\nResponse:")
                print(formatted)
    return

# Entry point: run the async agent loop
if __name__ == "__main__":
    asyncio.run(run_agent())