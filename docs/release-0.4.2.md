# Lun v0.4.2 — CI bootstrap fix and small producer demo

This patch release includes the CI fix and the new small interactive producer
examples. The runtime API and `stateless-producers-v4` contract are unchanged.
Dependencies remain Linen **v1.12.0** and Liaison's pure **v0.6.0** SDK.

## CI and deployment

The earlier end-to-end job failed before checkout because
`astral-sh/setup-uv@v9` could not be resolved. The workflow now selects the
published **v9.0.0** tag. Both workflows pass `actionlint`, and the referenced
action tags have been checked on GitHub.

Existing release tags retain their original commits and workflows. Publish this
new release commit and `v0.4.2` tag together on main. The Docker publisher waits
for successful push-to-main CI on that exact commit before building the image.
Creating the local tag alone does not trigger publication or deployment.

## Small interactive example

[`Examples/interactive`](../Examples/interactive/README.md) now demonstrates:

- `each [1,2,3]`: individual immediate emissions with `yieldAll`.
- `whole [1,2,3]`: a single list-valued emission with `yield`.
- `paced [1,2,3,4,5,6]`: a prefix, branches, loops and waits between emissions.
- `tick`: an increasing counter with a five-second repeat delay.
- `next [GRAPH]`: resume at the graph's next-call timestamp using an explicit
  demo clock, without wall-clock sleeping.
- `show [GRAPH]`: inspect independently retained graph replies.

The scripted demonstration verifies 16 checks over each of CLI and HTTP,
including empty lists, input replacement, propagation and scheduled resumption:

```sh
uv run Examples/interactive/run.py --demo
uv run Examples/interactive/run.py --transport http --demo
```

CI now runs both demonstrations. The existing illustrated guide and larger
producer cookbook remain available. Linux end-to-end and container verification
will be supplied by the required CI jobs after publication of the commit.
