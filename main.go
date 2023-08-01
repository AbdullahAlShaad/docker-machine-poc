package main

import (
	"context"
	"fmt"
	"github.com/povsister/scp"
	"golang.org/x/crypto/ssh"
	"google.golang.org/api/compute/v1"
	"google.golang.org/api/option"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"strings"
	"text/template"
	"time"
)

type gcp struct {
	EncodedCredential string
	Region            string
	ProjectID         string
	ClusterName       string
	GithubToken       string
	NetworkName       string
	SubnetCIDR        string
}

func main() {
	sshIntoMachine()
}

func fillScriptWithData() {
	var tmplFile = "capg_gke_cluster_create.sh"
	tmpl, err := template.New(tmplFile).ParseFiles(tmplFile)
	if err != nil {
		panic(err)
	}

	cur := gcp{
		EncodedCredential: "<enocoded_cred>",
		Region:            "<region>",
		ProjectID:         "<gcp_project>",
		ClusterName:       "shaad-test",
		NetworkName:       "vpc-shaad-test",
		GithubToken:       "<github_token>",
		SubnetCIDR:        "172.16.0.0/16",
	}
	outputFile, _ := os.Create("gcp-create.sh")
	defer outputFile.Close()
	err = tmpl.Execute(outputFile, cur)
	if err != nil {
		panic(err)
	}
}

func editScript() {
	filePath := "./startup-script.sh"
	newLine := "echo 'This is the new line'"

	content, err := ioutil.ReadFile(filePath)
	if err != nil {
		fmt.Printf("Error reading file: %v\n", err)
		return
	}

	scriptContent := string(content)

	lines := strings.Split(scriptContent, "\n")

	// Find the index where you want to insert the new line
	// For example, if you want to insert it after the 5th line:
	insertIndex := 8 // (1-based index, assuming the first line is at index 1)

	updatedLines := append(lines[:insertIndex-1], append([]string{newLine}, lines[insertIndex-1:]...)...)

	updatedScriptContent := strings.Join(updatedLines, "\n")

	var newFilePath = fmt.Sprintf("new-script.sh")
	err = ioutil.WriteFile(newFilePath, []byte(updatedScriptContent), 0644)
	if err != nil {
		fmt.Printf("Error writing to file: %v\n", err)
		return
	}

	fmt.Println("New line added successfully!")
}

// Generates an SSH key pair using the 'ssh-keygen' command
func generateSSHKeyPair() error {
	cmd := exec.Command("ssh-keygen", "-t", "rsa", "-b", "2048", "-f", "id_rsa", "-N", "")
	err := cmd.Run()
	if err != nil {
		return fmt.Errorf("failed to generate SSH key pair: %v", err)
	}
	return nil
}

func sshIntoMachine() {
	host := getInstaceIP()
	port := 22
	user := "docker-user"
	privateKeyPath := "/home/shaad/.docker/machine/machines/rancher-vm/id_rsa"

	// Read the private key file
	privateKeyBytes, err := os.ReadFile(privateKeyPath)
	if err != nil {
		log.Fatalf("Failed to read private key: %v", err)
	}

	// Parse the private key
	signer, err := ssh.ParsePrivateKey(privateKeyBytes)
	if err != nil {
		log.Fatalf("Failed to parse private key: %v", err)
	}

	// Configure the SSH client
	sshConfig := &ssh.ClientConfig{
		User: user,
		Auth: []ssh.AuthMethod{
			ssh.PublicKeys(signer),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         5 * time.Second,
	}

	// Establish the SSH connection
	conn, err := ssh.Dial("tcp", fmt.Sprintf("%s:%d", host, port), sshConfig)
	if err != nil {
		log.Fatalf("Failed to connect to SSH server: %v", err)
	}
	defer conn.Close()

	scpClient, err := scp.NewClientFromExistingSSH(conn, &scp.ClientOption{})

	file, err := os.CreateTemp("", "result-*.txt")
	if err != nil {
		fmt.Println("error")
	}
	defer os.Remove(file.Name())

	fo := &scp.FileTransferOption{
		Context:      context.TODO(),
		Timeout:      5 * time.Minute,
		PreserveProp: true,
	}
	err = scpClient.CopyFileFromRemote("/tmp/result.txt", file.Name(), fo)
	if err != nil {
		fmt.Println("NO file found")
	}

	fmt.Println("/tmp/result.txt file found")
}

func getInstaceIP() string {
	projectID := "appscode-testing"
	// Replace with the name of your instance
	instanceName := "rancher-vm"

	ctx := context.Background()

	// Create a compute service client
	gcpCredFile := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS")
	service, err := compute.NewService(ctx, option.WithCredentialsFile(gcpCredFile))
	if err != nil {
		log.Fatalf("Failed to create compute client: %v", err)
	}

	// Get the instance details
	instance, err := service.Instances.Get(projectID, "us-central1-a", instanceName).Do()
	if err != nil {
		log.Fatalf("Failed to get instance details: %v", err)
	}

	for _, networkInterface := range instance.NetworkInterfaces {
		for _, accessConfig := range networkInterface.AccessConfigs {
			if accessConfig.NatIP != "" {
				fmt.Println("Instance IP:", accessConfig.NatIP)
				return accessConfig.NatIP
			}
		}
	}

	fmt.Println("No IP address found for the instance.")
	return ""
}
