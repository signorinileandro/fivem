# FiveM Development Portfolio

This repository is a collection of personal FiveM resources built to explore and demonstrate real-world resource development practices. The projects focus on server-side architecture, QBCore integration, persistence, event security, entity lifecycle management, and modern NUI development.

The code is organized as independent resources so each project can be installed, reviewed, and discussed on its own.

## Projects

### ls-job-system

**Status:** In development — first implementation complete; in-game validation pending.

A server-authoritative delivery job for QBCore. It includes a configurable dispatcher NPC, a work vehicle, randomized delivery routes, server-side progression and payout validation, and persistent player statistics through oxmysql.

- [Resource documentation](./ls-job-system/README.md)
- [Interview notes](./ls-job-system/PORTFOLIO.md)

### ls-garage

**Status:** Planned.

A QBCore garage resource with a React and TypeScript NUI. This project has not been started.

### ls-admin

**Status:** Planned.

A server-validated administration panel with a React and TypeScript NUI. This project has not been started.

## Technologies

Currently used by the implemented resource:

- FiveM and Lua 5.4
- QBCore
- qb-target
- qb-vehiclekeys
- oxmysql
- MySQL or MariaDB

React, TypeScript, and Vite are planned for later projects but are not part of the current implementation.

## Repository Structure

```text
fivem-portfolio/
├── README.md
├── .gitignore
└── ls-job-system/
    ├── README.md
    ├── PORTFOLIO.md
    ├── fxmanifest.lua
    ├── config.lua
    ├── client/
    ├── server/
    ├── shared/
    └── sql/
```

Each project directory is intended to be copied into a FiveM server's `resources` directory as an independent resource.
