# Engineering Principles

These are the rules every plan, every line of code, and every test must respect — regardless of the host project's language, framework, or stack. Molcajete uses them; AI agents working in a Molcajete-set-up project see them in `CLAUDE.md` and in `.claude/rules/principles.md`.

## The Meta-Principle: Trust Comes from Tests, Not Code Shape

In AI-assisted development, code churns. Functions move, names change, files split and merge. The only signal that survives that churn is **behavior verified by tests**. If the integration tests pass and they cover the right thing, the code does its job — regardless of how it looks. If the tests are shallow or absent, no amount of human review compensates.

Everything below follows from that.

## 1. Integration Tests Are the Trust Contract

Integration tests drive the system through its public boundary — the same path real callers take. When they pass, the system *as a whole* satisfies the spec.

For Molcajete, integration tests are the **default test type**. They are written first and own the coverage floor (see Principle 4).

Unit tests are written **only** when the algorithm IS the contract: parsers, sort routines, encoders, hashing, math-heavy logic. The unit test exists because the integration test can't economically exercise every edge case. Picking unit over integration must be a **per-slice exception**, justified in the slice's plan.

## 2. Hexagonal Architecture Is the Default Shape

Code is organized around two kinds of ports:

- **Driver ports** — how the outside reaches the code: HTTP routes, GraphQL resolvers, CLI commands, event handlers, queue workers, cron tasks, public service methods. Listed in `specs/MODULES.md` per module under `Driving Ports`.
- **Driven ports** — how the code reaches the outside: databases, message buses, internal HTTP clients, file system, OS clock, external service SDKs.

Integration tests **drive through the driver ports** with the real internal stack running. They use **real driven ports** for everything the project owns (its own database, its own queues, its own internal services). Only **outer-edge driven ports** without sandboxes — third-party payment gateways, SMS providers, external APIs without test modes — get mocked.

This shape is universal. It does not dictate language, framework, or library.

## 3. Dependency Injection Makes Adapters Swappable

Wire dependencies through constructors, function arguments, or a DI container. Avoid module-level globals, ambient singletons, and import-time side effects. The test sets up the system with the adapters it wants and stubs only what it must.

DI is the principle. The mechanism (a DI container library, constructor injection, factory functions, pass-through arguments) is the host project's choice and lives in `specs/TECH-STACK.md`.

## 4. 80% Coverage Floor on Touched Files

Every task's touched files (`files.create ∪ files.modify ∪ {test_file}`) must hit at least 80% line coverage.

- The threshold is configurable via `.molcajete/settings.json testing.threshold`; 80% is the default and the floor.
- Coverage is scoped to **touched files**, not the whole project. The goal is "we proved this change works," not "we hit a global percentage."
- The host project's coverage collector (declared in `specs/TECH-STACK.md`'s **Coverage** rows per module) is the source of truth. When a module declares `not available`, `/m:build` makes a best-effort estimate against the floor and surfaces the estimate in its report.

## 5. Universal Software Craft

These rules apply regardless of stack. They are **navigation rules for the next AI agent** working in this code, not aesthetics:

- **Single responsibility.** One function does one thing. One module owns one concern.
- **Small functions.** Long functions hide bugs. If the function does not fit on one screen, split it.
- **Tell, don't ask.** Push work into the object that owns the data; don't pull data out to act on it externally.
- **Clear module boundaries.** Every module has a public API and an internal world. Other modules touch the public API only.
- **No god files.** When a file passes substantive responsibility for more than one concern, split it by responsibility — not by line count alone, but line count is a signal.
- **Refactor to reuse, never duplicate.** When you see a function that already exists, call it. When you see two functions doing the same thing, extract the shared logic. AI is uniquely prone to silent duplication — treat every "let me write a small helper" as an opportunity to grep first.
- **Patterns where they earn their keep.** Use well-known patterns (repository, command, observer, strategy) only where the situation calls for them. Don't impose patterns; recognize them.

A 3000-line file or a duplicated function is fog of war that compounds with every iteration. Shape is what makes navigation possible.

## 6. Principles Are Technology-Agnostic

This document does not specify a language, framework, runner, DI container, ORM, queue library, or coverage tool. Those are the host project's choices, recorded in `specs/TECH-STACK.md`. Principles bind regardless.

## How Molcajete Enforces These

| Command | Enforcement |
|---------|-------------|
| `/m:plan` | Designs architecture using hexagonal vocabulary. Each slice declares which driver port it drives and which driven ports its code reaches. Default sub-task is integration test; unit testing is an explicit, justified per-slice exception. |
| `/m:build` | Writes code that respects Principle 5 — small functions, clear boundaries, no god files, refactor-to-reuse. Coverage gate enforces Principle 4 against the host project's collector (or estimates when absent). |
| `uc-log` shared skill | Records every change. Principles don't decay over time because tests stay in place and the log makes new work explicit. |

## Override

The host project can edit `.claude/rules/principles.md` to adapt principles to their context — for example: "we always hit Stripe test mode and never mock the payments adapter." Molcajete reads the **host file first**; the plugin's `principles` skill is the default that ships in `.claude/rules/principles.md` at first `/m:setup`. Re-running `/m:setup` preserves the host file by default; the user can opt to regenerate from the plugin skill.
