#!/bin/bash

# Cilium + WASM Filter Test Setup Uninstallation Script
# Usage: ./uninstall.sh [--keep-cilium]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

KEEP_CILIUM=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --keep-cilium) KEEP_CILIUM=true ;;
        *) echo -e "${RED}Unknown parameter: $1${NC}"; exit 1 ;;
    esac
    shift
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Cilium + WASM Filter Test Uninstallation${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Step 1: Delete test stack
echo -e "${YELLOW}Step 1: Removing test stack...${NC}"

# Try each environment overlay (in case multiple were deployed)
for env in local dev stage prod; do
    if kubectl get namespace cilium-test &>/dev/null; then
        echo -e "${YELLOW}Deleting resources from ${env} overlay...${NC}"
        kubectl delete -k "overlays/${env}/" --ignore-not-found=true 2>/dev/null || true
    fi
done

# Delete namespace if still exists
if kubectl get namespace cilium-test &>/dev/null; then
    echo -e "${YELLOW}Deleting cilium-test namespace...${NC}"
    kubectl delete namespace cilium-test --ignore-not-found=true
fi

echo -e "${GREEN}✓ Test stack removed${NC}"
echo ""

# Step 2: Optionally remove Cilium
if [ "$KEEP_CILIUM" = false ]; then
    echo -e "${YELLOW}Step 2: Removing Cilium...${NC}"

    if command -v helm &>/dev/null && helm list -n kube-system | grep -q cilium; then
        echo -e "${YELLOW}Uninstalling Cilium via Helm...${NC}"
        helm uninstall cilium -n kube-system || true
    else
        echo -e "${YELLOW}Cilium not found via Helm, skipping...${NC}"
    fi

    echo -e "${GREEN}✓ Cilium removed${NC}"
    echo ""

    # Ask about CRDs
    echo -e "${YELLOW}Do you want to delete Cilium CRDs? (y/N)${NC}"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo -e "${YELLOW}Deleting Cilium CRDs...${NC}"
        kubectl get crd | grep cilium | awk '{print $1}' | xargs -r kubectl delete crd || true
        echo -e "${GREEN}✓ Cilium CRDs removed${NC}"
    else
        echo -e "${BLUE}Skipping CRD deletion${NC}"
    fi
else
    echo -e "${BLUE}Keeping Cilium as requested (--keep-cilium flag)${NC}"
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Uninstallation Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${GREEN}Resources removed:${NC}"
if kubectl get namespace cilium-test &>/dev/null; then
    echo -e "${YELLOW}Warning: cilium-test namespace still exists${NC}"
    kubectl get all -n cilium-test
else
    echo -e "${GREEN}✓ cilium-test namespace removed${NC}"
fi

if [ "$KEEP_CILIUM" = false ]; then
    echo ""
    echo -e "${GREEN}Cilium status:${NC}"
    if kubectl -n kube-system get pods -l k8s-app=cilium &>/dev/null; then
        echo -e "${YELLOW}Warning: Some Cilium pods still exist${NC}"
        kubectl -n kube-system get pods -l k8s-app=cilium
    else
        echo -e "${GREEN}✓ Cilium removed${NC}"
    fi
fi

echo ""
echo -e "${YELLOW}Note:${NC} Your kind cluster is still running."
echo -e "To delete the cluster: ${BLUE}kind delete cluster --name <cluster-name>${NC}"
