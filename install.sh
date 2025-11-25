#!/bin/bash

# Cilium + WASM Filter Test Setup Installation Script
# Usage: ./install.sh [environment]
# Example: ./install.sh local

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default environment
ENVIRONMENT="${1:-local}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Cilium + WASM Filter Test Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if environment overlay exists
if [ ! -d "overlays/${ENVIRONMENT}" ]; then
    echo -e "${RED}Error: Environment '${ENVIRONMENT}' not found${NC}"
    echo -e "Available environments: local, dev, stage, prod"
    exit 1
fi

echo -e "${GREEN}Installing for environment: ${ENVIRONMENT}${NC}"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command_exists kubectl; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ kubectl found${NC}"

if ! command_exists helm; then
    echo -e "${RED}Error: helm not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ helm found${NC}"

# Check if cluster is accessible
if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}Error: Cannot access Kubernetes cluster${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Kubernetes cluster accessible${NC}"
echo ""

# Step 1: Install Cilium
echo -e "${YELLOW}Step 1: Installing Cilium with Envoy support...${NC}"

# Check if Cilium is already installed
if helm list -n kube-system | grep -q cilium; then
    echo -e "${YELLOW}Cilium already installed. Upgrading...${NC}"
    helm upgrade cilium cilium/cilium \
        --namespace kube-system \
        --values base/cilium-values.yaml \
        --wait
else
    # Add Cilium repo if not exists
    if ! helm repo list | grep -q cilium; then
        echo -e "${YELLOW}Adding Cilium Helm repository...${NC}"
        helm repo add cilium https://helm.cilium.io/
        helm repo update
    fi

    echo -e "${YELLOW}Installing Cilium...${NC}"
    helm install cilium cilium/cilium \
        --namespace kube-system \
        --values base/cilium-values.yaml \
        --wait
fi

echo -e "${GREEN}✓ Cilium installed${NC}"
echo ""

# Wait for Cilium to be ready
echo -e "${YELLOW}Waiting for Cilium pods to be ready...${NC}"
kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s
echo -e "${GREEN}✓ Cilium pods ready${NC}"
echo ""

# Step 2: Deploy test stack
echo -e "${YELLOW}Step 2: Deploying test stack (${ENVIRONMENT})...${NC}"
kubectl apply -k "overlays/${ENVIRONMENT}/"

echo -e "${GREEN}✓ Test stack deployed${NC}"
echo ""

# Wait for backend to be ready
echo -e "${YELLOW}Waiting for backend pods to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=test-backend -n cilium-test --timeout=120s
echo -e "${GREEN}✓ Backend pods ready${NC}"
echo ""

# Display status
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Installation Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${GREEN}Resources deployed:${NC}"
kubectl -n cilium-test get all
echo ""

echo -e "${GREEN}CiliumEnvoyConfig:${NC}"
kubectl -n cilium-test get ciliumenvoyconfig
echo ""

echo -e "${GREEN}CiliumNetworkPolicy:${NC}"
kubectl -n cilium-test get ciliumnetworkpolicy
echo ""

echo -e "${YELLOW}Next steps:${NC}"
echo -e "1. Test the backend directly:"
echo -e "   ${BLUE}kubectl -n cilium-test port-forward svc/test-backend 8080:8080${NC}"
echo -e "   ${BLUE}curl http://localhost:8080/health${NC}"
echo ""
echo -e "2. Test through Envoy with WASM filter:"
echo -e "   ${BLUE}kubectl run -n cilium-test test-client --image=curlimages/curl:latest --rm -it --restart=Never -- sh${NC}"
echo -e "   Inside the pod:"
echo -e "   ${BLUE}curl http://test-backend.cilium-test.svc.cluster.local:8080/health${NC}"
echo -e "   ${BLUE}curl -X POST http://test-backend.cilium-test.svc.cluster.local:8080/echo -d '{\"test\":\"data\"}'${NC}"
echo ""
echo -e "3. Check Envoy logs for WASM filter:"
echo -e "   ${BLUE}kubectl -n kube-system logs -l k8s-app=cilium-envoy -f | grep -i wasm${NC}"
echo ""
echo -e "4. View Hubble UI for traffic visibility:"
echo -e "   ${BLUE}kubectl port-forward -n kube-system svc/hubble-ui 12000:80${NC}"
echo -e "   Open: ${BLUE}http://localhost:12000${NC}"
echo ""

echo -e "${GREEN}For more information, see README.md${NC}"
