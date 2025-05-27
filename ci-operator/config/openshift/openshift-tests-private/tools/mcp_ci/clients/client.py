#!/usr/bin/env python
"""
MCP client that connects to an MCP server, loads tools, and runs a chat loop using any LLM that you likes.
"""

import asyncio
import json
import os
import random
import sys

from dotenv import load_dotenv

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from langchain_mcp_adapters.tools import load_mcp_tools
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.prebuilt import create_react_agent
from langchain_openai import ChatOpenAI

from pydantic import BaseModel, Field
from typing import Union

load_dotenv()

# # Custom JSON encoder for objects with 'content' attribute
# class CustomEncoder(json.JSONEncoder):
#     def default(self, o):
#         if hasattr(o, "content"):
#             return {"type": o.__class__.__name__, "content": o.content}
#         return super().default(o)

if not os.getenv("SSL_CERT_FILE"):
    print("SSL_CERT_FILE is not set")
    sys.exit(1)

llm = ChatOpenAI(model=os.getenv("MODEL"),
                base_url=os.getenv("BASE_URL"),
                api_key=os.getenv("API_KET"),
                temperature=0.7,
                streaming=False
            )

class ChatResponse(BaseModel):
    """Chat response to the user"""
    conditions: str
    
class ListResponse(BaseModel):
    """Return a list of files to the user"""
    file_list: list = Field(description="A list of files")
    
class FinalResponse(BaseModel):
    """Final response to the user"""
    final_output: Union[ChatResponse, ListResponse]

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
checkpointer = InMemorySaver()

# Main async function: connect, load tools, create agent, run chat loop
async def run_agent():
    global mcp_client
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            mcp_client = type("MCPClientHolder", (), {"session": session})()
            tools = await load_mcp_tools(session)
            agent = create_react_agent(
                llm, 
                tools, 
                checkpointer=checkpointer,
                response_format=FinalResponse)
            thread_id = random.randint(40000, 50000)

            print("MCP Client Started!")
            print(" - Type 'quit' or 'q' to exit.")
            print(" - Type 'clear' to clear previous conversation and start a new one (AI can understand context in one conversation).")
            while True:
                query = input("\nQuery: ").strip()
                if query.lower() == "quit" or query.lower() == "q":
                    break
                if query.lower() == "clear":
                    rad = random.randint(1, 10)
                    thread_id += rad
                    continue
                config = {"configurable": {"thread_id": str(thread_id)}}
                    
                # Send user query to agent and print formatted response
                response = await agent.ainvoke({"messages": query}, config)

                # try:
                #     formatted = json.dumps(response, indent=2, cls=CustomEncoder)
                # except Exception:
                #     formatted = str(response)
                # print("\nResponse:")
                # print(formatted)
                print(response["structured_response"])
    return

# Entry point: run the async agent loop
if __name__ == "__main__":
    asyncio.run(run_agent())