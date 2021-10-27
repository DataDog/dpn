// https://docs.datadoghq.com/agent/guide/secrets-management/?tab=linux

package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/awserr"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/secretsmanager"
)

func main() {
	region, err := getRegion()
	if err != nil {
		log.Fatalf("Failed to parse region:\n%v", err.Error())
	}

	scanner := bufio.NewScanner(os.Stdin)
	if !scanner.Scan() {
		log.Fatalf("Failed to read: %v", scanner.Err())
	}

	text := secrets{}
	err = json.Unmarshal(scanner.Bytes(), &text)
	if err != nil {
		log.Fatalf("failed to unmasharl the object")
	}
	data := make(map[string]output)
	ch := make(chan output, len(text.Secrets))

	for _, secretKey := range text.Secrets {
		go getSecret(secretKey, region, ch)
		result := <-ch
		data[secretKey] = result
	}

	jsonString, _ := json.Marshal(data)
	fmt.Println(string(jsonString))
}

func getRegion() (string, error) {
	client := http.Client{
		Timeout: 2 * time.Second,
	}

	resp, err := client.Get("http://169.254.169.254/latest/dynamic/instance-identity/document/")
	if err != nil {
		return "", err
	}

	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	ec2matadata := metadata{}
	err = json.Unmarshal(body, &ec2matadata)
	if err != nil {
		return "", err
	}
	return ec2matadata.Region, nil
}

func getSecret(secretName, region string, ch chan output) {

	secretManagerSession, err := session.NewSession()
	if err != nil {
		log.Println(err.Error())
		ch <- output{"", "could not fetch the secret"}
		return
	}

	svc := secretsmanager.New(secretManagerSession,
		aws.NewConfig().WithRegion(region))
	input := &secretsmanager.GetSecretValueInput{
		SecretId:     aws.String(secretName),
		VersionStage: aws.String("AWSCURRENT"), // VersionStage defaults to AWSCURRENT if unspecified
	}

	// We only handle the specific exceptions for the 'GetSecretValue' API.
	// See https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html

	result, err := svc.GetSecretValue(input)
	if err != nil {
		if aerr, ok := err.(awserr.Error); ok {
			switch aerr.Code() {
			case secretsmanager.ErrCodeDecryptionFailure:
				// Secrets Manager can't decrypt the protected secret text using the provided KMS key.
				log.Println(secretsmanager.ErrCodeDecryptionFailure, aerr.Error())
				ch <- output{"", "could not fetch the secret"}
				return

			case secretsmanager.ErrCodeInternalServiceError:
				// An error occurred on the server side.
				log.Println(secretsmanager.ErrCodeInternalServiceError, aerr.Error())
				ch <- output{"", "could not fetch the secret"}
				return

			case secretsmanager.ErrCodeInvalidParameterException:
				// You provided an invalid value for a parameter.
				log.Println(secretsmanager.ErrCodeInvalidParameterException, aerr.Error())
				ch <- output{"", "could not fetch the secret"}
				return

			case secretsmanager.ErrCodeInvalidRequestException:
				// You provided a parameter value that is not valid for the current state of the resource.
				log.Println(secretsmanager.ErrCodeInvalidRequestException, aerr.Error())
				ch <- output{"", "could not fetch the secret"}
				return

			case secretsmanager.ErrCodeResourceNotFoundException:
				// We can't find the resource that you asked for.
				log.Println(secretsmanager.ErrCodeResourceNotFoundException, aerr.Error())
				ch <- output{"", "could not fetch the secret"}
				return

			}
		} else {
			// Print the error, cast err to awserr.Error to get the Code and
			// Message from an error.
			log.Println(aerr.Error())
			ch <- output{"", "could not fetch the secret"}
			return
		}
	}

	// Decrypts secret using the associated KMS CMK.
	// Depending on whether the secret is a string or binary, one of these fields will be populated.
	var secretString, decodedBinarySecret string
	var ddSecretValue ddSecret
	if result.SecretString != nil {
		secretString = *result.SecretString
		_ = json.Unmarshal([]byte(secretString), &ddSecretValue)
		if ddSecretValue.DDSecret == "" {
			ch <- output{"", "could not fetch the secret"}
		} else {
			ch <- output{ddSecretValue.DDSecret, ""}
		}
		return
	} else {
		decodedBinarySecretBytes := make([]byte, base64.StdEncoding.DecodedLen(len(result.SecretBinary)))
		len, err := base64.StdEncoding.Decode(decodedBinarySecretBytes, result.SecretBinary)
		if err != nil {
			log.Println("Base64 Decode Error:" + err.Error())
			ch <- output{"", "could not fetch the secret"}
			return
		}
		decodedBinarySecret = string(decodedBinarySecretBytes[:len])
		if decodedBinarySecret != "" {
			ch <- output{decodedBinarySecret, ""}
			return
		}
	}
	ch <- output{"", "could not fetch the secret"}
}

type secrets struct {
	Version string   `json:"version,omitempty"`
	Secrets []string `json:"secrets"`
}

type output struct {
	Value string `json:"value"`
	Err   string `json:"error"`
}

type ddSecret struct {
	DDSecret string `json:"dd-secret"`
}

type metadata struct {
	Region string `json:"region"`
}
