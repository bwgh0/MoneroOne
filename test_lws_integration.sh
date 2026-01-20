#!/bin/bash
# LWS Integration Test Script
# Tests the light wallet server endpoints

LWS_URL="http://REDACTED_IP:3000"
TEST_ADDRESS="9uACtnkMLeJP3iRsijiHNSCgsXKWqFif7g3B22Es1vtTUan9iFC1Uz3BEpjkNjQJcVc2a1vcRYPrNij6AJx45vNm5TGKeR7"
TEST_VIEW_KEY="43bd8555e966af8420eed1c9ea587757823869eac8f45f8a16efa9831f9ea308"

echo "=== LWS Integration Test ==="
echo ""

# Test 1: Login
echo "1. Testing /login..."
LOGIN_RESP=$(curl -s -X POST "$LWS_URL/login" \
  -H "Content-Type: application/json" \
  -d "{\"address\":\"$TEST_ADDRESS\",\"view_key\":\"$TEST_VIEW_KEY\",\"create_account\":true}")
echo "Response: $LOGIN_RESP"
echo ""

# Test 2: Get Address Info
echo "2. Testing /get_address_info..."
ADDR_INFO=$(curl -s -X POST "$LWS_URL/get_address_info" \
  -H "Content-Type: application/json" \
  -d "{\"address\":\"$TEST_ADDRESS\",\"view_key\":\"$TEST_VIEW_KEY\"}")
echo "Response: $ADDR_INFO"

# Extract balance
BALANCE=$(echo "$ADDR_INFO" | jq -r '.total_received // "0"')
echo "Balance: $BALANCE piconero"
echo ""

# Test 3: Get Unspent Outs
echo "3. Testing /get_unspent_outs..."
UNSPENT=$(curl -s -X POST "$LWS_URL/get_unspent_outs" \
  -H "Content-Type: application/json" \
  -d "{\"address\":\"$TEST_ADDRESS\",\"view_key\":\"$TEST_VIEW_KEY\",\"amount\":\"0\",\"dust_threshold\":\"2000000000\",\"mixin\":0,\"use_dust\":true}")
echo "Response: $UNSPENT"

# Check outputs
OUTPUT_COUNT=$(echo "$UNSPENT" | jq '.outputs | length')
echo "Output count: $OUTPUT_COUNT"

# Validate tx_pub_key format
if [ "$OUTPUT_COUNT" -gt 0 ]; then
  TX_PUB_KEY=$(echo "$UNSPENT" | jq -r '.outputs[0].tx_pub_key')
  TX_PUB_KEY_LEN=${#TX_PUB_KEY}
  echo "tx_pub_key: $TX_PUB_KEY (length: $TX_PUB_KEY_LEN)"

  # Check if 64 hex chars
  if [ "$TX_PUB_KEY_LEN" -eq 64 ] && [[ "$TX_PUB_KEY" =~ ^[0-9a-fA-F]+$ ]]; then
    echo "✓ tx_pub_key format is valid"
  else
    echo "✗ tx_pub_key format is INVALID"
  fi

  # Show full output structure
  echo ""
  echo "Full output[0] structure:"
  echo "$UNSPENT" | jq '.outputs[0]'
  # Show full output structure
  echo ""
  echo "Full output[0] structure:"
  echo "$UNSPENT" | jq '.outputs[0]'
fi
echo ""

# Test 4: Get Random Outs (Decoys)
echo "4. Testing /get_random_outs (Amount 0)..."
RAND_OUTS=$(curl -s -X POST "$LWS_URL/get_random_outs" \
  -H "Content-Type: application/json" \
  -d "{\"count\":10,\"amounts\":[\"0\"]}")
# echo "Response: $RAND_OUTS"
OUTS_COUNT=$(echo "$RAND_OUTS" | jq '.amount_outs[0].outputs | length')
echo "Decoy count for amount 0: $OUTS_COUNT"
echo ""

# Test 4: Get Address Txs
echo "4. Testing /get_address_txs..."
TXS=$(curl -s -X POST "$LWS_URL/get_address_txs" \
  -H "Content-Type: application/json" \
  -d "{\"address\":\"$TEST_ADDRESS\",\"view_key\":\"$TEST_VIEW_KEY\"}")
TX_COUNT=$(echo "$TXS" | jq '.transactions | length')
echo "Transaction count: $TX_COUNT"
echo ""

echo "=== Test Complete ==="
