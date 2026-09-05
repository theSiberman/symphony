# Domain glossary

## Product Spec

A parent work item whose completed behavior is integrated and accepted as one coherent change.

## Tracer

A child work item that delivers one end-to-end slice of its parent Product Spec. A tracer belongs
to exactly one Product Spec.

## Integration target

The destination into which a work item's changes must merge. A tracer's integration target is its
parent Product Spec; an unrelated standalone work item's integration target is `main`.

## Integration branch

The single branch that accumulates all tracers for one Product Spec before acceptance. Its name is
`spec/<product-spec-number>-<slug>`.

## UAT evidence

The result of accepting a Product Spec against one exact integration-branch commit. Any change to
that commit invalidates the evidence.
