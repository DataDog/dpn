package azureSecretManager

import (
	"context"
	"fmt"
	"log"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/keyvault/azsecrets"
)

func GetSecrets(keyVaultName string, secretsKeys []string) map[string]map[string]string {

	keyVaultURL := fmt.Sprintf("https://%s.vault.azure.net/", keyVaultName)

	//Create a credential using the NewDefaultAzureCredential type.
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		log.Fatalf("failed to obtain a credential: %v", err)
	}

	//Establish a connection to the Key Vault client
	client, err := azsecrets.NewClient(keyVaultURL, cred, nil)
	var errMSg string
	if err != nil {
		log.Fatalf("failed to connect to client: %v", err)
		errMSg = err.Error()
	}

	res := map[string]map[string]string{}
	for _, handle := range secretsKeys {
		resp, err := client.GetSecret(context.TODO(), handle, nil)
		if err != nil {
			log.Fatalf("failed to get the secret: %v", err)
		}

		res[handle] = map[string]string{
			"value": *resp.Value,
			"error": errMSg,
		}
	}

	return res
}
