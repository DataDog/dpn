## A Quick Guide for Creating an Azure KeyVault `.exe` Secrets Fetcher For Use with Datadog

Assumptions:
- This was done as a quick and dirty PoC using the Azure Portal, I'm sure this can be done using CLI/Terraform etc... however I just wanted to verify that I could get it working quickly
- You have a Windows 2019 or newer Azure VM to test with

### In Azure

1. Follow this doc to create an Azure KeyVault using the Portal: https://docs.microsoft.com/en-us/azure/key-vault/secrets/quick-create-portal, set it up using RBAC so you can use IAM and role-based access.
2. Create a new secret in Azure KeyVault called `secret1`, and a second one called `secret2`.
3. Using IAM, assign the `KeyVault Secrets User` role to your test VM: 
    <img src="https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/E0uj6pX6/1fc58d10-cccc-421a-900e-a154b96333bc.jpg?v=9341a80658c54a2ca16b14d2ced55c60" width="500">
4. On your VM, install Python3 (https://www.python.org/downloads/) + required Python Packages:
   ```powershell
   pip install azure-identity
   pip install azure-keyvault-secrets
   ```
5. Create a new Python file called `get_secrets.py` and add the following contents:
    ```python
    import os
    import cmd
    import logging
    import sys
    import json
    from azure.keyvault.secrets import SecretClient
    from azure.identity import DefaultAzureCredential
    
    # This filters out a false warn log
    def filter_environment_credential_warning(record):
        if record.name.startswith("azure.identity") and record.levelno == logging.WARNING:
            message = record.getMessage()
            return not message.startswith("EnvironmentCredential.get_token")
        return True

    handler = logging.StreamHandler(sys.stdout)
    handler.addFilter(filter_environment_credential_warning)
    logging.basicConfig(level=logging.WARN, handlers=[handler])

    # Set your KeyVault name here, or use an env variable
    # keyVaultName = os.environ["KEY_VAULT_NAME"]
    keyVaultName = "your-keyvault-name"
    KVUri = f"https://{keyVaultName}.vault.azure.net"

    credential = DefaultAzureCredential()
    client = SecretClient(vault_url=KVUri, credential=credential)

    secretName = "test-secret"
    retrieved_secret = client.get_secret(secretName)

    print(json.dumps({'secret1' : retrieved_secret1.value, 'secret2' : retrieved_secret2.value}))
    ```
6. Test that your Python script works by running `python.exe get_secrets.py` from within the same dir you created the file in.
7. Once you see your results, now we need to convert it to an `.exe` file.
8. Run `pip install pyinstaller`, this is an open source Python to EXE converter: https://www.pyinstaller.org/
9. Next, run `pyinstaller.exe --onefile .\get_secrets.py` from within the same dir as the Python file you created.
10. In the same dir, a new dir will be created after you run this command called `dist`, cd into the dir and run the new command `get_secrets.exe`, you should see your secrets output just as they were with the Python script.
11. You can now use this application in your Datadog config as outlined here: https://docs.datadoghq.com/agent/guide/secrets-management/?tab=windows#providing-an-executable

### Permissions
The Datadog Agent won't launch if the permissions are not set properly on the file, they should be as follows:

- `SYSTEM` group has full control
- `Administrators` group has full control
- `ddagenteruser` (or whatever the Agent's user was named) user has read & execute access (full control worked, too)


