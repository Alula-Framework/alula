# ALU-WEB-2010: The server could not listen on its address

**Severity:** error

## Meaning

The HTTP server could not bind the host and port it was configured with:
another process is listening there, the port needs privileges, or the address
is not on this machine. The report names the address and the reason.

## Why Alula rejects it

Nothing can be served without it, so the start fails — with the address,
where it used to print the socket call's errno and no address at all.

## Common causes

- Another instance of the application, or another service, already on the port.
- A port below 1024 without the privilege to bind it.
- `server.host` set to an address this machine does not have.

## Fixes

1. Stop whatever holds the port, or choose another with `server.port`.
2. Set `server.host` to an address this machine has, or `0.0.0.0` for all of them.

## Related

ALU-LIFE-8004.
