package steps

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/AlaudaDevops/bdd/config"
	"github.com/AlaudaDevops/bdd/logger"
	"github.com/AlaudaDevops/bdd/variable"
	"github.com/cucumber/godog"
	"go.uber.org/zap"
	"gopkg.in/yaml.v3"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

type rbacUserConfig struct {
	Name      string `yaml:"name"`
	Namespace string `yaml:"namespace"`
	Role      string `yaml:"role"`
}

type rbacInstanceConfig struct {
	InstanceName string `yaml:"instanceName"`
	Namespace    string `yaml:"namespace"`
	Cluster      string `yaml:"cluster"`
	Path         string `yaml:"path"`
}

type rbacTestContext struct {
	users    map[string]*rbacUserInfo
	instance *rbacInstanceConfig
	client   *http.Client
	baseURL  string
	cluster  string
	k8sClt   *kubernetes.Clientset
}

type rbacUserInfo struct {
	ServiceAccount string
	Token          string
	Namespace      string
	Role           string
}

var (
	rbacContexts     = make(map[string]*rbacTestContext)
	rbacContextsLock sync.RWMutex
)

func getOrCreateRBACContext(ctx context.Context, cluster string) *rbacTestContext {
	rbacContextsLock.Lock()
	defer rbacContextsLock.Unlock()

	if cluster == "" {
		cfg := config.FromContext(ctx)
		if cfg != nil {
			if acp, ok := cfg.Data["acp"].(map[string]interface{}); ok {
				if clusterVal, ok := acp["cluster"].(string); ok {
					cluster = clusterVal
				}
			}
		}
	}

	if rbacCtx, exists := rbacContexts[cluster]; exists {
		return rbacCtx
	}

	rbacCtx := &rbacTestContext{
		users:   make(map[string]*rbacUserInfo),
		client:  &http.Client{Timeout: 30 * time.Second},
		cluster: cluster,
	}

	if os.Getenv("INSECURE_SKIP_TLS_VERIFY") == "true" {
		rbacCtx.client.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: true,
			},
		}
	}

	cfg := config.FromContext(ctx)
	if cfg != nil {
		if acp, ok := cfg.Data["acp"].(map[string]interface{}); ok {
			if baseURL, ok := acp["baseUrl"].(string); ok {
				rbacCtx.baseURL = baseURL
			}
			if clusterVal, ok := acp["cluster"].(string); ok {
				rbacCtx.cluster = clusterVal
			}
		}
	}

	rbacContexts[cluster] = rbacCtx
	return rbacCtx
}

func stepCreateSonarqubeInstanceWithToken(ctx context.Context, roleName string, params *godog.DocString) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)

	var instanceConfig rbacInstanceConfig
	if err := yaml.Unmarshal([]byte(params.Content), &instanceConfig); err != nil {
		return ctx, fmt.Errorf("failed to unmarshal instance config: %v", err)
	}

	rbacCtx := getOrCreateRBACContext(ctx, instanceConfig.Cluster)
	rbacCtx.instance = &instanceConfig

	user, ok := rbacCtx.users[roleName]
	if !ok {
		return ctx, fmt.Errorf("user %s not found", roleName)
	}

	log.Info("Creating Sonarqube instance with token", zap.String("role", roleName), zap.String("instance", instanceConfig.InstanceName), zap.String("cluster", rbacCtx.cluster))

	url := fmt.Sprintf("%s/kubernetes/%s/apis/operator.alaudadevops.io/v1alpha1/namespaces/%s/sonarqubes",
		rbacCtx.baseURL, rbacCtx.cluster, instanceConfig.Namespace)

	if instanceConfig.Path == "" {
		return ctx, fmt.Errorf("path is required in instance config")
	}

	instanceBody, err := getSonarqubeInstanceBodyFromFile(ctx, instanceConfig.InstanceName, instanceConfig.Namespace, instanceConfig.Path)
	if err != nil {
		return ctx, fmt.Errorf("failed to get instance body from file: %v", err)
	}

	req, err := http.NewRequest("POST", url, bytes.NewReader(instanceBody))
	if err != nil {
		return ctx, fmt.Errorf("failed to create request: %v", err)
	}

	req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", user.Token))
	req.Header.Set("Content-Type", "application/json")

	resp, err := rbacCtx.client.Do(req)
	if err != nil {
		return ctx, fmt.Errorf("failed to send request: %v", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	log.Info("Create instance response",
		zap.Int("status", resp.StatusCode),
		zap.String("role", roleName),
		zap.String("response", string(body)))

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		log.Info("Successfully created instance", zap.String("role", roleName), zap.String("instance", instanceConfig.InstanceName))
	} else {
		return ctx, fmt.Errorf("failed to create instance: status=%d, body=%s", resp.StatusCode, string(body))
	}

	return ctx, nil
}

func getK8sClient(cluster string) (*kubernetes.Clientset, error) {
	rbacCtx := getOrCreateRBACContext(context.Background(), cluster)
	if rbacCtx.k8sClt != nil {
		return rbacCtx.k8sClt, nil
	}

	var kubeconfig string
	if home := homedir.HomeDir(); home != "" {
		kubeconfig = filepath.Join(home, ".kube", "config")
	}

	if envKubeconfig := os.Getenv("KUBECONFIG"); envKubeconfig != "" {
		kubeconfig = envKubeconfig
	}

	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return nil, fmt.Errorf("failed to build kubeconfig: %v", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create kubernetes client: %v", err)
	}

	rbacCtx.k8sClt = clientset
	return clientset, nil
}

func stepCreateRBACUser(ctx context.Context, roleName string, params *godog.DocString) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)

	var config rbacUserConfig
	if err := yaml.Unmarshal([]byte(params.Content), &config); err != nil {
		return ctx, fmt.Errorf("failed to unmarshal rbac user config: %v", err)
	}

	rbacCtx := getOrCreateRBACContext(ctx, "")
	clt, err := getK8sClient(rbacCtx.cluster)
	if err != nil {
		return ctx, fmt.Errorf("failed to get k8s client: %v", err)
	}

	saName := config.Name
	if saName == "" {
		saName = fmt.Sprintf("%s-sa", roleName)
	}

	log.Info("Creating ServiceAccount", zap.String("name", saName), zap.String("namespace", config.Namespace))

	sa := &corev1.ServiceAccount{
		ObjectMeta: v1.ObjectMeta{
			Name:      saName,
			Namespace: config.Namespace,
		},
	}

	_, err = clt.CoreV1().ServiceAccounts(config.Namespace).Create(ctx, sa, v1.CreateOptions{})
	if err != nil && !errors.IsAlreadyExists(err) {
		return ctx, fmt.Errorf("failed to create service account: %v", err)
	}

	if err := createRBACRoleAndBinding(ctx, clt, saName, config.Namespace, config.Role); err != nil {
		return ctx, fmt.Errorf("failed to create RBAC role and binding: %v", err)
	}

	token, err := createServiceAccountToken(ctx, clt, saName, config.Namespace)
	if err != nil {
		return ctx, fmt.Errorf("failed to create service account token: %v", err)
	}

	rbacCtx.users[roleName] = &rbacUserInfo{
		ServiceAccount: saName,
		Token:          token,
		Namespace:      config.Namespace,
		Role:           config.Role,
	}

	log.Info("Successfully created RBAC user", zap.String("role", roleName), zap.String("sa", saName))
	return ctx, nil
}

func createRBACRoleAndBinding(ctx context.Context, clt *kubernetes.Clientset, saName, namespace, role string) error {
	log := logger.LoggerFromContext(ctx)

	var rules []rbacv1.PolicyRule
	roleName := fmt.Sprintf("%s-role", saName)

	switch role {
	case "platform-admin":
		rules = []rbacv1.PolicyRule{
			{
				APIGroups: []string{"operator.alaudadevops.io"},
				Resources: []string{"sonarqubes"},
				Verbs:     []string{"get", "list", "watch", "create", "update", "patch", "delete"},
			},
			{
				APIGroups: []string{"*"},
				Resources: []string{"*"},
				Verbs:     []string{"*"},
			},
		}
		roleName = "platform-admin-role"
	case "ns-admin":
		rules = []rbacv1.PolicyRule{
			{
				APIGroups: []string{"operator.alaudadevops.io"},
				Resources: []string{"sonarqubes"},
				Verbs:     []string{"get", "list", "watch", "update", "patch"},
			},
			{
				APIGroups: []string{""},
				Resources: []string{"secrets", "configmaps", "pods", "services"},
				Verbs:     []string{"*"},
			},
		}
		roleName = "ns-admin-role"
	case "project-admin":
		rules = []rbacv1.PolicyRule{
			{
				APIGroups: []string{"operator.alaudadevops.io"},
				Resources: []string{"sonarqubes"},
				Verbs:     []string{"get", "list", "watch", "update", "patch"},
			},
		}
		roleName = "project-admin-role"
	case "developer":
		rules = []rbacv1.PolicyRule{
			{
				APIGroups: []string{"operator.alaudadevops.io"},
				Resources: []string{"sonarqubes"},
				Verbs:     []string{"get", "list", "watch"},
			},
		}
		roleName = "developer-role"
	case "auditor":
		rules = []rbacv1.PolicyRule{
			{
				APIGroups: []string{"operator.alaudadevops.io"},
				Resources: []string{"sonarqubes"},
				Verbs:     []string{"get", "list", "watch"},
			},
		}
		roleName = "auditor-role"
	default:
		return fmt.Errorf("unknown role: %s", role)
	}

	rbacRole := &rbacv1.Role{
		ObjectMeta: v1.ObjectMeta{
			Name:      roleName,
			Namespace: namespace,
		},
		Rules: rules,
	}

	_, err := clt.RbacV1().Roles(namespace).Create(ctx, rbacRole, v1.CreateOptions{})
	if err != nil && !errors.IsAlreadyExists(err) {
		return fmt.Errorf("failed to create role: %v", err)
	}

	log.Info("Created/Updated Role", zap.String("name", roleName), zap.String("namespace", namespace))

	rbacBinding := &rbacv1.RoleBinding{
		ObjectMeta: v1.ObjectMeta{
			Name:      fmt.Sprintf("%s-binding", roleName),
			Namespace: namespace,
		},
		Subjects: []rbacv1.Subject{
			{
				Kind:      "ServiceAccount",
				Name:      saName,
				Namespace: namespace,
			},
		},
		RoleRef: rbacv1.RoleRef{
			Kind: "Role",
			Name: roleName,
		},
	}

	_, err = clt.RbacV1().RoleBindings(namespace).Create(ctx, rbacBinding, v1.CreateOptions{})
	if err != nil && !errors.IsAlreadyExists(err) {
		return fmt.Errorf("failed to create role binding: %v", err)
	}

	log.Info("Created/Updated RoleBinding", zap.String("name", fmt.Sprintf("%s-binding", roleName)))
	return nil
}

func createServiceAccountToken(ctx context.Context, clt *kubernetes.Clientset, saName, namespace string) (string, error) {
	log := logger.LoggerFromContext(ctx)

	secretName := fmt.Sprintf("%s-token", saName)
	secret := &corev1.Secret{
		ObjectMeta: v1.ObjectMeta{
			Name:      secretName,
			Namespace: namespace,
			Annotations: map[string]string{
				"kubernetes.io/service-account.name": saName,
			},
		},
		Type: corev1.SecretTypeServiceAccountToken,
	}

	_, err := clt.CoreV1().Secrets(namespace).Create(ctx, secret, v1.CreateOptions{})
	if err != nil && !errors.IsAlreadyExists(err) {
		return "", fmt.Errorf("failed to create secret: %v", err)
	}

	var token string
	err = wait.PollImmediate(2*time.Second, 30*time.Second, func() (bool, error) {
		secret, err := clt.CoreV1().Secrets(namespace).Get(ctx, secretName, v1.GetOptions{})
		if err != nil {
			return false, nil
		}
		if secret.Data == nil || len(secret.Data["token"]) == 0 {
			return false, nil
		}
		token = string(secret.Data["token"])
		return true, nil
	})

	if err != nil {
		return "", fmt.Errorf("failed to wait for token: %v", err)
	}

	log.Info("Created ServiceAccount token", zap.String("secret", secretName))
	return token, nil
}

func stepShouldCreateInstance(ctx context.Context, roleName string) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)
	log.Info("Verified: user can create instance", zap.String("role", roleName))
	return ctx, nil
}

func stepShouldNotCreateInstanceWithCheck(ctx context.Context, roleName string, params *godog.DocString) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)

	var instanceConfig rbacInstanceConfig
	if err := yaml.Unmarshal([]byte(params.Content), &instanceConfig); err != nil {
		return ctx, fmt.Errorf("failed to unmarshal instance config: %v", err)
	}

	rbacCtx := getOrCreateRBACContext(ctx, instanceConfig.Cluster)

	user, ok := rbacCtx.users[roleName]
	if !ok {
		return ctx, fmt.Errorf("user %s not found", roleName)
	}

	if instanceConfig.Path == "" {
		return ctx, fmt.Errorf("path is required for permission check")
	}

	url := fmt.Sprintf("%s/kubernetes/%s/apis/operator.alaudadevops.io/v1alpha1/namespaces/%s/sonarqubes",
		rbacCtx.baseURL, rbacCtx.cluster, instanceConfig.Namespace)

	instanceBody, err := getSonarqubeInstanceBodyFromFile(ctx, instanceConfig.InstanceName+"-test", instanceConfig.Namespace, instanceConfig.Path)
	if err != nil {
		return ctx, fmt.Errorf("failed to get instance body from file: %v", err)
	}

	req, err := http.NewRequest("POST", url, bytes.NewReader(instanceBody))
	if err != nil {
		return ctx, fmt.Errorf("failed to create request: %v", err)
	}

	req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", user.Token))
	req.Header.Set("Content-Type", "application/json")

	resp, err := rbacCtx.client.Do(req)
	if err != nil {
		return ctx, fmt.Errorf("failed to send request: %v", err)
	}
	defer resp.Body.Close()

	log.Info("Create instance response (expected to fail)", zap.Int("status", resp.StatusCode), zap.String("role", roleName))

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return ctx, fmt.Errorf("expected permission denied, but request succeeded")
	}

	log.Info("Verified: user cannot create instance", zap.String("role", roleName))
	return ctx, nil
}

func stepShouldNotCreateInstance(ctx context.Context, roleName string) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)
	log.Info("Verified: user cannot create instance", zap.String("role", roleName))
	return ctx, nil
}

func stepShouldViewInstance(ctx context.Context, roleName string, params *godog.DocString) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)

	var instanceConfig rbacInstanceConfig
	if err := yaml.Unmarshal([]byte(params.Content), &instanceConfig); err != nil {
		return ctx, fmt.Errorf("failed to unmarshal instance config: %v", err)
	}

	rbacCtx := getOrCreateRBACContext(ctx, instanceConfig.Cluster)

	user, ok := rbacCtx.users[roleName]
	if !ok {
		return ctx, fmt.Errorf("user %s not found", roleName)
	}

	url := fmt.Sprintf("%s/frontend-plugins/clusters/console-plugins?filter=types%%3Ddeploy-instance%%3Bclusters%%3D%s%%3Boperators%%3Dsonarqube-ce-operator",
		rbacCtx.baseURL, rbacCtx.cluster)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return ctx, fmt.Errorf("failed to create request: %v", err)
	}

	req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", user.Token))

	resp, err := rbacCtx.client.Do(req)
	if err != nil {
		return ctx, fmt.Errorf("failed to send request: %v", err)
	}
	defer resp.Body.Close()

	log.Info("View instance response", zap.Int("status", resp.StatusCode), zap.String("role", roleName))

	if resp.StatusCode != http.StatusOK {
		return ctx, fmt.Errorf("expected status 200, got %d", resp.StatusCode)
	}

	log.Info("Successfully viewed instance", zap.String("role", roleName))
	return ctx, nil
}

func performUpdateRequest(ctx context.Context, roleName string, instanceConfig *rbacInstanceConfig) (int, []byte, error) {
	log := logger.LoggerFromContext(ctx)

	rbacCtx := getOrCreateRBACContext(ctx, instanceConfig.Cluster)

	user, ok := rbacCtx.users[roleName]
	if !ok {
		return 0, nil, fmt.Errorf("user %s not found", roleName)
	}

	url := fmt.Sprintf("%s/kubernetes/%s/apis/operator.alaudadevops.io/v1alpha1/namespaces/%s/sonarqubes/%s",
		rbacCtx.baseURL, rbacCtx.cluster, instanceConfig.Namespace, instanceConfig.InstanceName)

	getReq, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return 0, nil, fmt.Errorf("failed to create get request: %v", err)
	}
	getReq.Header.Set("Authorization", fmt.Sprintf("Bearer %s", user.Token))

	getResp, err := rbacCtx.client.Do(getReq)
	if err != nil {
		return 0, nil, fmt.Errorf("failed to get instance: %v", err)
	}
	defer getResp.Body.Close()

	if getResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(getResp.Body)
		return 0, nil, fmt.Errorf("failed to get current instance: status=%d, body=%s", getResp.StatusCode, string(body))
	}

	currentBody, err := io.ReadAll(getResp.Body)
	if err != nil {
		return 0, nil, fmt.Errorf("failed to read current instance: %v", err)
	}

	var currentInstance map[string]interface{}
	if err := json.Unmarshal(currentBody, &currentInstance); err != nil {
		return 0, nil, fmt.Errorf("failed to unmarshal current instance: %v", err)
	}

	updateBodyFromFile, err := getSonarqubeInstanceBodyFromFile(ctx, instanceConfig.InstanceName, instanceConfig.Namespace, instanceConfig.Path)
	if err != nil {
		return 0, nil, fmt.Errorf("failed to get instance body from file: %v", err)
	}

	var updateInstance map[string]interface{}
	if err := json.Unmarshal(updateBodyFromFile, &updateInstance); err != nil {
		return 0, nil, fmt.Errorf("failed to unmarshal update instance: %v", err)
	}

	if currentMetadata, ok := currentInstance["metadata"].(map[string]interface{}); ok {
		if updateMetadata, ok := updateInstance["metadata"].(map[string]interface{}); ok {
			updateMetadata["resourceVersion"] = currentMetadata["resourceVersion"]
			updateMetadata["uid"] = currentMetadata["uid"]
			updateMetadata["creationTimestamp"] = currentMetadata["creationTimestamp"]
			updateMetadata["generation"] = currentMetadata["generation"]
			if managedFields, ok := currentMetadata["managedFields"]; ok {
				updateMetadata["managedFields"] = managedFields
			}
		}
	}

	finalUpdateBody, err := json.Marshal(updateInstance)
	if err != nil {
		return 0, nil, fmt.Errorf("failed to marshal final update body: %v", err)
	}

	req, err := http.NewRequest("PUT", url, bytes.NewReader(finalUpdateBody))
	if err != nil {
		return 0, nil, fmt.Errorf("failed to create request: %v", err)
	}

	req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", user.Token))
	req.Header.Set("Content-Type", "application/json")

	resp, err := rbacCtx.client.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("failed to send request: %v", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	log.Info("Update instance response", zap.Int("status", resp.StatusCode), zap.String("role", roleName), zap.String("body", string(body)))

	return resp.StatusCode, body, nil
}

func stepShouldUpdateInstance(ctx context.Context, roleName string, params *godog.DocString) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)

	var instanceConfig rbacInstanceConfig
	if err := yaml.Unmarshal([]byte(params.Content), &instanceConfig); err != nil {
		return ctx, fmt.Errorf("failed to unmarshal instance config: %v", err)
	}

	if instanceConfig.Path == "" {
		return ctx, fmt.Errorf("path is required for update operation")
	}

	statusCode, body, err := performUpdateRequest(ctx, roleName, &instanceConfig)
	if err != nil {
		return ctx, err
	}

	if statusCode == http.StatusUnauthorized || statusCode == http.StatusForbidden {
		return ctx, fmt.Errorf("permission denied: status=%d, body=%s", statusCode, string(body))
	}

	log.Info("User has permission to update instance", zap.String("role", roleName), zap.Int("status", statusCode))
	return ctx, nil
}

func stepShouldNotUpdateInstance(ctx context.Context, roleName string, params *godog.DocString) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)

	var instanceConfig rbacInstanceConfig
	if err := yaml.Unmarshal([]byte(params.Content), &instanceConfig); err != nil {
		return ctx, fmt.Errorf("failed to unmarshal instance config: %v", err)
	}

	if instanceConfig.Path == "" {
		return ctx, fmt.Errorf("path is required for permission check")
	}

	statusCode, body, err := performUpdateRequest(ctx, roleName, &instanceConfig)
	if err != nil {
		return ctx, err
	}

	if statusCode == http.StatusUnauthorized || statusCode == http.StatusForbidden {
		log.Info("Verified: user cannot update instance (permission denied)", zap.String("role", roleName))
		return ctx, nil
	}

	return ctx, fmt.Errorf("expected permission denied (401/403), but got status=%d, body=%s", statusCode, string(body))
}

func getSonarqubeInstanceBodyFromFile(ctx context.Context, name, namespace, filePath string) ([]byte, error) {
	renderedPath, err := variable.RenderVariableInFile(ctx, filePath, false)
	if err != nil {
		return nil, fmt.Errorf("failed to render variables in file %s: %v", filePath, err)
	}

	data, err := os.ReadFile(renderedPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read file %s: %v", renderedPath, err)
	}

	var instance map[string]interface{}
	if err := yaml.Unmarshal(data, &instance); err != nil {
		return nil, fmt.Errorf("failed to unmarshal yaml: %v", err)
	}

	if metadata, ok := instance["metadata"].(map[string]interface{}); ok {
		metadata["name"] = name
		metadata["namespace"] = namespace
	}

	jsonData, err := json.Marshal(instance)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal json: %v", err)
	}

	return jsonData, nil
}
