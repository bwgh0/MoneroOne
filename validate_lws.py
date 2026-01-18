import sys
import json
import re

def validate_hex(s, length):
    if len(s) != length:
        return False
    return bool(re.match(r'^[0-9a-fA-F]+$', s))

try:
    data = json.load(sys.stdin)
    
    if "outputs" in data:
        print(f"Checking {len(data['outputs'])} outputs...")
        for i, out in enumerate(data['outputs']):
            pubkey = out.get('tx_pub_key')
            if not pubkey:
                print(f"Error: Output {i} missing tx_pub_key")
                sys.exit(1)
            
            # Check length and content
            if not validate_hex(pubkey, 64):
                print(f"Error: Output {i} has invalid tx_pub_key: '{pubkey}' len={len(pubkey)}")
                # Print hex repr to see hidden chars
                print(f"Hex repr: {pubkey.encode('utf-8').hex()}")
                sys.exit(1)
            else:
                print(f"Output {i} tx_pub_key valid: {pubkey}")
                
    elif "transactions" in data:
        print(f"Checking {len(data['transactions'])} transactions...")
        for i, tx in enumerate(data['transactions']):
            # Check spent_outputs presence
            if "spent_outputs" not in tx:
                 print(f"Error: Transaction {i} missing spent_outputs")
                 sys.exit(1)
            else:
                 print(f"Transaction {i} has spent_outputs ({len(tx['spent_outputs'])} items)")

    print("Validation Successful")

except Exception as e:
    print(f"Validation Error: {e}")
    sys.exit(1)
