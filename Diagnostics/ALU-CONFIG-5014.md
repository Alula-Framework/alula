# ALU-CONFIG-5014: A configuration key under a spelling Alula no longer reads

**Severity:** error

## Meaning

A configuration layer sets a key under a name it had before it was renamed,
such as `pubsub.node_id` for `pubsub.node-id`, or `alula.presence.node-name`
for `presence.node-name`. The message names the old key, the new key and the
layer that sets it:

```
alula: could not start.
error: [ALU-CONFIG-5014] Configuration key 'pubsub.node_id' is set in alula.yaml, but it was renamed 'pubsub.node-id' and the old spelling is no longer read. Rename it to 'pubsub.node-id'; Alula stops here rather than start without the value you set.
```

## Why Alula rejects it

Alula used to read both spellings. That left a deployment with two names for
one setting, and it could not simply stop reading the old one: the setting
would go back to its default without a word, and a node ID or a timeout
would change in production with nothing in the log. Refusing to start names
the key to change instead.

The old spelling is refused even when the new one is set too, because one of
the two lines is not doing what it looks like it does.

The environment-variable layer is the exception. It turns every character
other than a letter or digit into `_`, so `ALULA_PUBSUB_NODE_ID` is how both
`pubsub.node_id` and `pubsub.node-id` are written, and it is read as the new
key. A variable that spells only the old key, such as
`ALULA_ALULA_PRESENCE_NODE_NAME`, is refused, and the message names it:
`is set in the environment variable ALULA_ALULA_PRESENCE_NODE_NAME`.

## Fixes

1. Rename the key to the spelling the message gives:

   ```yaml
   # before
   pubsub:
     node_id: api-3
   # after
   pubsub:
     node-id: api-3
   ```

2. For an environment variable, rename the variable, e.g.
   `ALULA_ALULA_CHANNELS_OUTBOUND_BUFFER_SIZE` to
   `ALULA_CHANNELS_OUTBOUND_BUFFER_SIZE`.

The renamed keys are `pubsub.node_id` and `pubsub.broadcast_timeout`; the
`alula.presence.*` and `alula.channels.*` keys, which lost their `alula.`;
and the snake_case `security.oidc.*` keys, such as `jwks_url` and
`client_id`, which are now kebab-case.

## Related

ALU-CONFIG-5004, ALU-CONFIG-5012.
