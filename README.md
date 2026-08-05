# boutique-platform-infra

Contains infrastructure and deployment automation for the Boutique platform.

## Overview

- **Type:** Platform repository
- **Stack:** Git, Docker

## Flow

```text
Client / service → Controller → Business logic → Database / events / downstream services
```

## CI/CD

This repository is built and deployed independently through its own GitHub Actions workflow.
