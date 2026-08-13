# ls-job-system

## Overview

`ls-job-system` is a configurable delivery job resource for QBCore. A player starts a shift through a dispatcher NPC, receives a server-selected route and a work van, completes each stop in order, returns the vehicle, and receives a server-calculated payment. Completed-job statistics are persisted with oxmysql.

The first implementation is complete and has been statically reviewed. It still requires validation in a running FiveM/QBCore environment.

## Features

- Configurable dispatcher NPC with qb-target actions
- Randomized routes without repeated destinations in the same shift
- Optional server-created work vehicle with spawn obstruction checks
- Server-side work-vehicle key assignment and revocation
- Bounded, server-generated work plates without reuse during the resource lifetime
- Delivery markers, routed blips, interaction feedback, and return routing
- Server-owned session state and ordered progression
- Server-side player, character, state, distance, and duplicate-event validation
- Server-calculated per-stop reward and completion bonus
- One-statement statistics upsert through oxmysql
- Session and vehicle cleanup on disconnect, cancellation, and resource stop
- Client session resynchronization after a client resource restart
- Debug logging controlled by `Config.Debug`

## Tech Stack

- FiveM with Lua 5.4 and OneSync
- QBCore (`qb-core`)
- qb-target
- oxmysql
- MySQL or MariaDB
- qb-vehiclekeys

## Compatibility Contract

The implementation targets the current upstream interfaces documented by the FiveM and QBCore projects:

- `exports['qb-core']:GetCoreObject()`
- `QBCore.Functions.GetPlayer(source)`
- `QBCore.Functions.CreateVehicle(source, model, vehicleType, coords, warp)`
- `Player.Functions.AddMoney(account, amount, reason)`
- `exports['qb-target']:AddEntityZone(name, entity, zoneOptions, targetOptions)`
- `exports['qb-target']:RemoveZone(name)`
- `exports['qb-vehiclekeys']:GiveKeys(source, plate)`
- `exports['qb-vehiclekeys']:RemoveKeys(source, plate)`
- `exports['qb-vehiclekeys']:HasKeys(source, plate)`
- `MySQL.update.await(query, parameters)` from `@oxmysql/lib/MySQL.lua`

The manifest declares `/onesync`, `qb-core`, `qb-target`, `qb-vehiclekeys`, and `oxmysql` as runtime requirements. Pin compatible dependency versions in a real server. If an existing QBCore installation predates server-side `QBCore.Functions.CreateVehicle`, or its qb-vehiclekeys version lacks these server exports, update the dependency or adapt the relevant integration only after checking that installation's source.

## Architecture

```text
Player / qb-target
        ↓
client/main.lua        NPC, marker, blip, animation, local UX
        ↓ net events
server/main.lua        authoritative session, order, distance, vehicle keys, payout
        ↓
QBCore                 player identity and money account
        ↓
server/repository.lua  one parameterized statistics upsert
        ↓
MySQL / MariaDB
```

The client asks for an action; it does not report a reward or authoritative progress. The server stores the selected delivery list, current index, completed count, character identifier, vehicle entity, and session status. Only the current destination is sent to the client for display.

`server/repository.lua` contains persistence only. This keeps SQL out of the event handlers and makes the point at which durable statistics are written easy to identify.

## Security

The resource treats every network event as attacker-controlled.

- Start requests require a loaded QBCore player, no existing/starting session, a cooldown, and server-observed proximity to the dispatcher.
- A per-attempt start token prevents a disconnect or source reuse during asynchronous vehicle creation from installing a stale session.
- Delivery requests contain no destination index or payment. The server reads the expected stop from its own session.
- A delivery is accepted only for the same active `citizenid`, in the delivering state, at the expected index, and within the configured server-side distance.
- A processing lock and per-action cooldown reject duplicate or concurrent attempts.
- Finish requests require every assigned delivery, the awaiting-return state, player proximity to the depot, and—when configured—the exact server-created job vehicle near the depot.
- The reward is generated exclusively from server configuration and the server's completed-delivery count.
- The session is moved to a paying state. After successful `AddMoney`, it is removed before awaiting statistics persistence, so another finish attempt cannot reuse it.
- Work-vehicle keys are granted and verified server-side. Cleanup revokes them before deleting the vehicle; this matters when qb-vehiclekeys persists key metadata.
- Disconnect, cancellation, and resource-stop handlers discard temporary state, revoke assigned keys when the player object is available, and delete the assigned vehicle.

### Server event audit

All resource events below are client-callable and therefore treated as untrusted. None accepts gameplay data from the client.

| Event | Client data | Server validation | State change | Main abuse addressed |
| --- | --- | --- | --- | --- |
| `ls-job-system:server:requestStart` | None | Cooldown, loaded Player, no active/pending session, matching character throughout startup, proximity to dispatcher, free spawn, unique plate, valid vehicle/network ID, confirmed keys | Creates one session | Remote start, concurrent starts, duplicate vehicles, stale `source` reuse |
| `ls-job-system:server:requestState` | None | Cooldown and matching `citizenid` | No authoritative gameplay change; returns a snapshot | State discovery for another character, request spam |
| `ls-job-system:server:completeDelivery` | None | Cooldown, session/character, `delivering` state, processing lock, expected server-held destination, server-observed proximity | Advances exactly one delivery or changes to `awaiting_return` | Arbitrary index, remote delivery, replay/concurrent advancement |
| `ls-job-system:server:finishJob` | None | Cooldown, session/character, `awaiting_return`, all deliveries complete, processing lock, player at depot, stored vehicle handle/network ID/model at depot; plate mismatches are logged as anomalies | Pays once, detaches session, cleans assets, persists stats | Client-selected reward, early/remote finish, wrong vehicle, duplicate payout |
| `ls-job-system:server:cancelJob` | None | Cooldown and matching session character | Detaches session and cleans vehicle/keys without payment | Cancelling another character's session, cleanup spam |

The client cannot directly write statistics: the repository is called only by the validated finish path with server-owned values.

### Distance-validation limitation

Server-side `GetPlayerPed` and `GetEntityCoords` use OneSync's synchronized entity state. This is materially stronger than accepting coordinates from the client, but updates can be delayed and coordinates ultimately originate from the networked game state. The configured radius therefore includes reasonable latency tolerance. This check blocks simple remote event execution; it is not a complete antiteleport or anticheat system.

### Payment and statistics consistency

QBCore money and portfolio statistics are stored by different systems, so they cannot participate in one database transaction here. Payment is performed first. If the statistics upsert fails, the payment is not rolled back and the server logs the failure. The completion result is sent only if the source still belongs to the same character and has no newer active or starting session. A future extension could enqueue failed statistics writes for retry.

## Installation

### Requirements

- A current FiveM server artifact with OneSync enabled
- A working QBCore server
- `oxmysql`
- `qb-target` and its `PolyZone` dependency
- `qb-vehiclekeys` with the current server-side `GiveKeys`, `RemoveKeys`, and `HasKeys` exports
- MySQL or MariaDB (MariaDB is recommended by the oxmysql documentation)

### Steps

1. Copy `ls-job-system` into a resource directory, for example:

   ```text
   C:\FXServer\server-data\resources\[local]\ls-job-system
   ```

2. Run [`sql/install.sql`](./sql/install.sql) against the same database configured for QBCore.

3. Confirm that the connection string appears before resource startup and that dependencies start in this order:

   ```cfg
   set mysql_connection_string "user=fivem;password=CHANGE_ME;host=127.0.0.1;port=3306;database=qbcore"
   set onesync on

   ensure oxmysql
   ensure qb-core
   ensure PolyZone
   ensure qb-target
   ensure qb-vehiclekeys
   ensure ls-job-system
   ```

4. Restart the server and confirm there are no manifest, dependency, configuration, or SQL errors in the FXServer console.

Never commit the real database password, Cfx registration key, or `server.cfg` to this repository.

## Configuration

All gameplay tuning is in [`config.lua`](./config.lua):

- `Config.JobNPC`: model, location, heading, scenario, and target distance
- `Config.WorkVehicle`: enable flag, model/type, spawn, plate format and bounded generation attempts, client entity timeout, and return rule. Reserve its plate prefix for work vehicles on the target server.
- `Config.ReturnPoint`: depot location and validation radius
- `Config.DeliveriesPerJob`: minimum and maximum route length
- `Config.DeliveryLocations`: candidate destinations with stable IDs
- `Config.Validation`: server-side distances and event cooldowns
- `Config.Rewards`: QBCore money account, per-stop range, and completion bonus
- `Config.Interaction`: marker style, client draw distance, and delivery duration
- `Config.Blips`: delivery and return-route presentation
- `Config.Debug`: concise additional server/client logs when `true`

The configured maximum route length must not exceed the number of delivery locations. Invalid ranges, duplicate IDs, missing coordinates, and invalid vehicle settings fail early when the server script loads.

## Testing

### Manual happy path

1. Join with a loaded QBCore character and approach the dispatcher at the configured depot.
2. Use qb-target and start a shift.
3. Confirm that one Speedo is created, the player receives keys, and the first route appears.
4. Visit each marker and press `E`. Confirm that only one stop advances at a time.
5. After the final stop, confirm that the route changes back to the depot.
6. Return the assigned van, target the dispatcher, and finish the shift.
7. Confirm that the bank balance increases by a value consistent with the server configuration.
8. Query `ls_delivery_stats` and verify one job, the correct delivery count, and the exact paid amount.

### Negative and lifecycle cases

- Try to start twice; no second session or vehicle should appear.
- Trigger the delivery interaction repeatedly; progress should increase only once.
- Attempt a delivery outside the validation radius; the server should reject it.
- Try to finish before all stops, away from the depot, without the assigned vehicle, and twice after payment.
- Cancel at the NPC; the session and job vehicle should be removed without payment.
- After cancellation and completion, verify that qb-vehiclekeys no longer reports the old work plate in the player's persisted key metadata.
- Disconnect during a route and reconnect; the old session must not pay.
- Restart `ls-job-system`; NPCs, blips, sessions, and work vehicles should be cleaned up and recreated only where appropriate.
- Stop MySQL temporarily only in a disposable development environment; verify payment succeeds, the statistics failure is logged, and no duplicate payment becomes possible.

For deliberate event-forging tests, use a separate local-only test resource and never install it on a public server.

## Local Windows Test Environment

The least error-prone current path is txAdmin's QBCore recipe:

1. Install GTA V and the FiveM client, Git, 7-Zip, and MariaDB. HeidiSQL is optional but convenient.
2. Download the **latest recommended** Windows server artifact from the [official Cfx.re server setup guide](https://docs.fivem.net/docs/getting-started/setup-fivem-server/). Extract it to a dedicated directory such as `C:\FXServer\server`.
3. Run `FXServer.exe` with no `+exec` arguments. Open `http://localhost:40120` if txAdmin does not open automatically, enter the console PIN, and link the Cfx account.
4. Generate the server registration key through the Cfx Portal link shown by txAdmin. A key is still part of the documented setup at the time this guide was written; verify the current Cfx instructions rather than using an old Keymaster tutorial.
5. Choose **Popular Recipes → QBCore Framework** in txAdmin. The [official QBCore Windows guide](https://docs.qbcore.org/qbcore-documentation/guides/windows-installation) is the source of truth if recipe names or screens change.
6. Create a dedicated MariaDB database and least-privileged local user. Let the QBCore recipe import its schema, then confirm the generated `mysql_connection_string` works. The [oxmysql documentation](https://overextended.dev/docs/oxmysql) recommends MariaDB and requires the connection string before `oxmysql` starts.
7. Confirm the recipe installed `qb-core` and `oxmysql`. Install the current [qb-target repository](https://github.com/qbcore-framework/qb-target) plus its declared `PolyZone` dependency, and the current [qb-vehiclekeys repository](https://github.com/qbcore-framework/qb-vehiclekeys), if the recipe did not include them.
8. Execute [`sql/install.sql`](./sql/install.sql) in the QBCore database using HeidiSQL or the MariaDB client.
9. Copy this project directory to `resources\[local]\ls-job-system` under the txAdmin profile's server-data directory.
10. Add `ensure ls-job-system` after `oxmysql`, `qb-core`, `PolyZone`, `qb-target`, and `qb-vehiclekeys` in `server.cfg`. Ensure OneSync is enabled; the `/onesync` manifest constraint will reject startup otherwise.
11. Save the configuration and start/restart the server from txAdmin. Resolve every dependency or SQL error before joining.
12. Launch FiveM. Use the LAN server entry or press `F8` and run `connect 127.0.0.1:30120` if the local server uses the default port.
13. Create/load a QBCore character, travel to the configured NPC, and execute the happy-path and negative tests above.
14. Capture console logs, screenshots, the exact dependency commits/tags, and the test date for a reproducible portfolio validation record.

If txAdmin's recipe or Cfx registration workflow differs, stop and follow the linked official documentation; those distribution steps change independently of this resource.

## Screenshots

No screenshots are included yet. Useful captures after in-game validation would be:

- Dispatcher NPC and qb-target interaction
- Active delivery marker and realistic gameplay context
- GPS route and destination blip
- Completed-shift notification
- `ls_delivery_stats` row after completion

## Known Limitations

- The resource has not yet been validated in-game; current confidence comes from source review and the static checks documented for this repository.
- Server-side proximity checks depend on OneSync's synchronized entity state and allow a configurable tolerance for network delay.
- Server-authoritative validation reduces common event-injection and replay attacks, but it is not a replacement for a dedicated anticheat.
- Runtime compatibility depends on the exact FiveM artifact and QBCore dependency versions. The interfaces listed in the compatibility contract must be checked when versions are pinned or upgraded.
- Plate collision checks cover this resource's reservations and currently spawned vehicles, not records in custom garage schemas; the configured prefix should therefore be reserved for this resource.

## Future Improvements

- Retry queue or audit table for statistics writes that fail after payment
- Optional localized strings file
- Server-owned package inventory item when gameplay requirements justify it
- Observability hooks for structured admin logs
- Automated integration test resource for event abuse and lifecycle scenarios
