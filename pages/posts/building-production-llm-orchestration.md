---
title: Building Production LLM Orchestration from Scratch
date: 2026/2/23
description: How we built a multi-model inference pipeline with ReAct agents, type-safe tool execution, and provider-agnostic abstractions — serving real B2B customers.
tag: llm, ai, engineering
author: Francisco Utrera
---

Most LLM orchestration tutorials show you how to call the OpenAI API. Production LLM orchestration is a different animal. You need multi-model routing, constrained agent behavior, tool execution with real APIs, cross-service tracing, and the ability to swap providers without rewriting your application. Over the past two years at Embrace.ai, I built all of this from scratch. Here's what I learned.

## The Problem

Embrace is an AI-powered customer self-service platform. When a customer asks a question through a chat widget, Slack bot, or Teams integration, an AI agent needs to:

1. Understand the question
2. Search the company's knowledge base (RAG)
3. Optionally call external tools (Zendesk tickets, Jira issues, Salesforce records)
4. Generate a grounded response with citations

This sounds straightforward until you realize each step involves making architectural decisions that compound. Which model handles which task? How do you coordinate tool execution across services? What happens when a tool call fails mid-conversation? How do you prevent the agent from hallucinating actions it shouldn't take?

## Provider-Agnostic LLM SDK

The first thing I built was `@embrace-ai/llm-sdk` — a provider-agnostic abstraction layer over OpenAI, Anthropic Claude, and Google Vertex AI.

The core idea is a `BaseModel` abstraction that normalizes the interface across providers. Each provider has different APIs, different tool-calling formats, different streaming semantics, and different ways of expressing structured output. The SDK hides all of that behind a consistent interface.

The key design decisions:

**Type-safe tool definitions via Zod.** Tools are defined using Zod schemas, which gives us runtime validation and TypeScript type inference in a single definition. When an LLM returns a tool call, the arguments are validated against the schema before execution. This catches malformed tool calls before they hit downstream services.

**ReAct agent loop.** The SDK implements a ReAct (Reasoning + Acting) loop: the model reasons about what to do, calls a tool, observes the result, and decides whether to continue or respond. The loop runs automatically — you define the tools and the agent figures out the execution plan. This is not a simple chain; it's a multi-step reasoning loop with automatic tool execution.

**Hooks system.** `onStart`, `onLLMResponse`, `onToolResult`, `onEnd` — these hooks let consuming services inject behavior at every stage of the inference pipeline. We use them for logging, cost tracking, and business logic enforcement.

**Cross-service trace propagation.** Every LLM call gets a Langfuse trace ID that propagates across service boundaries via OpenTelemetry. When a single user question triggers an LLM call that triggers a tool execution that triggers a RAG search, the entire chain is visible in a single trace. This is critical for debugging production issues.

## Two Execution Paths

The orchestration service (`generation-llm`) implements two distinct execution paths:

**Direct generation** — the model produces structured JSON output. Used for classification, extraction, and evaluation tasks where you need a specific output format, not a conversational response.

**Tool execution (ReAct agent flow)** — the model enters a reasoning loop and can call tools. This is the path for customer-facing conversations. The orchestration service coordinates with the tool execution engine via GraphQL polling (1-second intervals, 10-minute timeout). When the model decides to call a tool, the request goes to `generation-tool`, which executes it and returns results.

Why polling instead of WebSockets or server-sent events? Reliability. In a microservice architecture running on AWS Lambda, long-lived connections are fragile. Polling with idempotent state transitions is boring but it works at 3 AM when your on-call engineer is asleep.

## Multi-Model Routing

Not every task needs GPT-4. Our system routes to different models based on the task:

- **Complex reasoning / tool-use conversations**: GPT-4o or Claude 3.5 Sonnet
- **Document enrichment (table descriptions, image analysis)**: Claude (best at multi-modal understanding of structured content)
- **Summary generation**: Gemini Flash (fast, cheap, good enough for summaries)
- **Embeddings**: OpenAI text-embedding-ada-002 (for RAG) and text-embedding-3-large (for semantic clustering)
- **Reranking**: Cohere rerank-english-v3.0 / multilingual-v3.0 (not an LLM call, but part of the pipeline)

The routing logic lives in the orchestration service, not in the SDK. The SDK doesn't care which model it's talking to — it just needs to know the provider and model name. This separation means we can change routing decisions without touching the SDK.

## Constrained Agent Behavior

One of the harder problems in production LLM deployment is preventing the agent from doing things it shouldn't. In a B2B support context, the agent needs to:

- Only answer questions using the company's knowledge base
- Never make up information
- Never take actions (create tickets, send emails) without explicit configuration
- Stay on topic for the configured agent persona

We implemented a constrained agent behavior system that enforces these rules at the orchestration layer. The agent configuration (instructions, allowed tools, personality, constraints) is managed by a separate service. The orchestration layer loads this configuration before every conversation and injects it into the system prompt and tool availability.

This is not just prompt engineering. The tool availability itself is constrained — if an agent isn't configured to use the email tool, the tool isn't even presented to the model. You can't jailbreak a tool that doesn't exist in your context.

## Tool Execution Framework

The tool execution engine is its own service with a surprisingly rich feature set:

**Connection tools** auto-discover OAuth API endpoints. When a customer connects their Zendesk instance, the system introspects the available API endpoints and generates tool definitions automatically. The LLM can then query Zendesk tickets, search Jira issues, or look up Salesforce records without any custom integration code per customer.

**Custom tools** let customers define their own HTTP endpoints as tools. The agent can call any REST API the customer configures, with schema validation on inputs and outputs.

**Knowledge retrieval** is itself a tool — the agent decides when to search the knowledge base rather than having it hardcoded into every request. This means the agent can sometimes answer from context without a RAG lookup, reducing latency.

**Code sandbox** execution runs in isolated ECS Fargate containers for safe code execution.

All tool execution is async via SQS, with step capture for visibility into what the agent did and why.

## What I'd Do Differently

**Start with structured output earlier.** We spent months on freeform text generation before realizing that most of our non-conversational use cases (classification, evaluation, extraction) work better with structured JSON output. If I were starting over, I'd build the structured output path first.

**Invest in evaluation infrastructure from day one.** We added Langfuse tracing mid-stream and had to backfill. Knowing the cost per model, per customer, per conversation from the start would have informed routing decisions much earlier.

**Don't over-abstract providers too early.** The SDK's provider abstraction was essential, but I over-engineered parts of it before I understood how each provider's tool-calling semantics actually differed in practice. Build the abstraction after you've integrated two providers, not before.

## The Stack

For reference, the full technology stack:

- **TypeScript/Node.js** on AWS Lambda + ECS Fargate
- **OpenAI, Anthropic, Google Vertex AI** for LLM inference
- **Zod** for type-safe tool schema definitions
- **Apollo Server + GraphQL Federation** across 68 microservices
- **SQS/SNS** for async tool execution
- **Langfuse** for LLM observability with OpenTelemetry trace propagation
- **Inngest** for durable workflows
- **Drizzle ORM + PostgreSQL** for persistence

The system handles production traffic for B2B support teams, processing thousands of conversations daily across multiple model providers. It's been running for over two years, and the architectural decisions made early — provider abstraction, async tool execution, constrained behavior — have held up well as the product evolved.
