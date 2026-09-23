# Test Web3Signer EIP-4844

To test EIP-4844 in Web3Signer eth1 mode, from separate terminals:
- Run Besu + Teku via kurtosis
- Run Web3Signer in eth1 mode connected to Besu
- Run Python3 based test script.

## Run Besu + Teku minimal-FULU network

Update images if required.

```sh
cd kurtosis
kurtosis run --enclave besu-teku github.com/ethpandaops/ethereum-package --args-file besu-teku-minimal.yml
```

## Run Web3Signer in eth1 mode
```sh
cd web3signer-eth1
docker compose up
```
To test a locally built image, set `WEB3SIGNER_IMAGE` (defaults to `consensys/web3signer:develop`):
```sh
WEB3SIGNER_IMAGE=web3signer:develop docker compose up
```

## Run Tests
Make sure that genesis is completed (can be observed via Dora at http://127.0.0.1:36000)

```sh
cd python-test
```
Create Python virtual environment, activate and install requirements
```sh
python3 -m venv venv
source ./venv/bin/activate
pip install -r ./requirements.txt  
```
Run test
```sh
python3 test_blob_tx.py
```

# Clean up

Kurtosis
```sh
cd kurtosis
kurtosis clean -a
```

Web3Signer (Either hit CTRL+C and/or use following commands)
```sh
cd we3signer-eth1
docker compose down
```

Python virtual environment
```sh
deactivate
```