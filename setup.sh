#!/bin/bash

sudo chown -R claude:claude /claude/workspace/Server/.build
cd /claude/workspace/Server && docker compose up -d
