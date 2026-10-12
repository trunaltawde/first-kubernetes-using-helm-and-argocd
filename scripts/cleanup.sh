#!/usr/bin/env bash
kind delete cluster --name "${1:-lab}"
