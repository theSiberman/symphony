# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

The dispatch queue defaults to priority, then oldest first. A newer blocker inherits
the best queue position of the active tickets waiting on it, including through
dependency chains. Ranking is recalculated each poll without interrupting running
workers or admitting paused, excluded or still-blocked tickets.

Host admission can be configured with `agent.admission_command`. It runs once
asynchronously before an idle dispatch decision, bounded to 90 seconds (plus a
five-second process-group kill allowance, using the host `timeout` command).
Exit zero admits work; missing executables, failures and stale results mean host
waiting. Polling/reconciliation remain responsive; labels and retry counts are
unchanged by host waiting. The snapshot/API exposes `admission.status` and `reason`.

Retries rejoin the ordinary dependency/priority selection when their backoff is
due. Only running workers consume execution slots. Normal continuation resets the
abnormal-failure count; `agent.max_abnormal_retries` defaults to three. Exhaustion
preserves work and asks the tracker adapter to persist an exception. GitHub uses
`needs-info` and removes queue-membership labels. An unsupported or unavailable
adapter leaves a visible in-memory block and logs the persistence failure; that
failure must be resolved before restarting the scheduler.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

GitHub deployments can opt into scheduler-owned running audit labels. Symphony reconciles
these labels with live workers on startup, worker exit, and subsequent polls, so paused,
failed, and completed tickets do not depend on an agent's final cleanup instruction.
See the [GitHub adapter configuration](elixir/README.md#github-issues-adapter) for ownership scope.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
