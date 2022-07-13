package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"os"

	"secretBackend/src/awsSecretManager"
	"secretBackend/src/azureSecretManager"
)

func main() {

	// help flag
	needHelp()

	checkArguments(2)

	// reading secrect values based on the input secret provider
	var output map[string]map[string]string
	switch cloud := os.Args[1]; cloud {
	case "aws":
		checkArguments(4)
		output = awsSecretManager.GetSecrets(os.Args[2], os.Args[3], readSecretInput().Secrets)
	case "azure":
		checkArguments(3)
		output = azureSecretManager.GetSecrets(os.Args[2], readSecretInput().Secrets)
	default:
		fmt.Println("no valid secret provider is given, use -h flag for more information.")
		return
	}

	// writing the secret values to std output
	fmt.Print(string(toJason(output)))
}

func needHelp() {
	helpPtr := flag.Bool("h", false, "help")
	flag.Parse()

	if *helpPtr {
		fmt.Print("First argument should be secret provider e.g azure or aws .\n"+
		"Second argument should be secret name.\n"+
		"if aws is chosen the third parameter should be the aws region.")
		os.Exit(1)
	}
}

func checkArguments(x int) {
	if len(os.Args) < x {
		fmt.Fprintf(os.Stderr, "valid arguments are required, use -h flag for more information.")
		os.Exit(1)
	}
}

func toJason(secretData map[string]map[string]string) []byte {
	output, err := json.Marshal(secretData)
	if err != nil {
		fmt.Fprintf(os.Stderr, "could not serialize res: %s", err)
		os.Exit(1)
	}
	return output
}

func readSecretInput() secretKeysPayload {
	data, err := ioutil.ReadAll(os.Stdin)

	if err != nil {
		fmt.Fprintf(os.Stderr, "Could not read from stdin: %s", err)
		os.Exit(1)
	}

	secrets := secretKeysPayload{}
	json.Unmarshal(data, &secrets)
	return secrets
}

type secretKeysPayload struct {
	Secrets []string
	Version int
}
