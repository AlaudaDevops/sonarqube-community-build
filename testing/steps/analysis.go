package steps

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"time"

	"github.com/AlaudaDevops/bdd/logger"
	"github.com/cucumber/godog"
	"go.uber.org/zap"
	"gopkg.in/yaml.v3"
)

type AnalysisParams struct {
	Host       string `yaml:"host" json:"host"`
	User       string `yaml:"user" json:"user"`
	Pwd        string `yaml:"pwd" json:"pwd"`
	Token      string `yaml:"token" json:"token"`
	Component  string `yaml:"component" json:"component"`
	Branch     string `yaml:"branch" json:"branch"`
	MaxRetries int    `yaml:"maxRetries" json:"maxRetries"`
	Sleep      int    `yaml:"sleep" json:"sleep"`
}

func WaitForAnalysis(ctx context.Context, params *godog.DocString) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)
	input := AnalysisParams{}
	if err := yaml.Unmarshal([]byte(params.Content), &input); err != nil {
		log.Error("failed to unmarshal analysis params", zap.Error(err))
		return ctx, err
	}

	input = defaultParams(input)

	var err error
	input.Token, err = getToken(ctx, input)
	if err != nil {
		log.Error("failed to get token", zap.Error(err))
		return ctx, err
	}

	ctx, err = waitAnalysis(ctx, input)
	if err != nil {
		log.Error("failed to wait analysis", zap.Error(err))
		return ctx, err
	}

	return ctx, nil
}

func waitAnalysis(ctx context.Context, params AnalysisParams) (context.Context, error) {
	log := logger.LoggerFromContext(ctx)
	url := fmt.Sprintf("%s/api/ce/activity?component=%s&type=REPORT&branch=%s", params.Host, params.Component, params.Branch)
	log.Debug("wait analysis", zap.String("url", url))

	for i := 0; i < params.MaxRetries; i++ {
		// Use curl instead of a Go HTTP client: against the remote ctyun-VM ingress
		// the Go client (resty) returns EOF while a plain curl to the identical
		// endpoint succeeds at the same instant (pod Ready throughout). A GET on a
		// bad connection is also retried here regardless.
		out, err := exec.CommandContext(ctx, "curl", "-s", "-k", "--max-time", "30",
			"-H", "Authorization: Bearer "+params.Token, url).Output()
		if err != nil {
			log.Info("failed to check analysis result, retrying", zap.Error(err))
			time.Sleep(time.Duration(params.Sleep) * time.Second)
			continue
		}

		result := struct {
			Tasks []struct {
				Status string `json:"status"`
			} `json:"tasks"`
		}{}
		if err := json.Unmarshal(out, &result); err != nil {
			log.Info("failed to parse analysis result, retrying", zap.Error(err), zap.String("response", string(out)))
			time.Sleep(time.Duration(params.Sleep) * time.Second)
			continue
		}

		success := len(result.Tasks) > 0
		for _, task := range result.Tasks {
			if task.Status != "SUCCESS" {
				success = false
				break
			}
		}
		if success {
			return ctx, nil
		}

		if i == params.MaxRetries-1 {
			log.Info("analysis failed, and max retries reached", zap.String("response", string(out)))
		}
		log.Info("analysis is running, waiting...", zap.Int("sleep", params.Sleep))
		time.Sleep(time.Duration(params.Sleep) * time.Second)
	}
	return ctx, fmt.Errorf("analysis failed, and max retries reached")
}

func defaultParams(params AnalysisParams) AnalysisParams {
	if params.MaxRetries == 0 {
		params.MaxRetries = 20
	}
	if params.Sleep == 0 {
		params.Sleep = 5
	}
	if params.Branch == "" {
		params.Branch = "main"
	}
	return params
}

func getToken(ctx context.Context, params AnalysisParams) (string, error) {
	log := logger.LoggerFromContext(ctx)
	log.Info("get token", zap.String("host", params.Host), zap.String("user", params.User))
	if params.Token != "" {
		return params.Token, nil
	}

	url := fmt.Sprintf("%s/api/user_tokens/generate?name=my-token-%s", params.Host, time.Now().Format("20060102150405"))
	log.Debug("get token", zap.String("url", url))

	// Use curl (fresh connection per call, like the scan scripts) rather than a Go
	// HTTP client (resty): against the remote ctyun-VM ingress the resty POST returns
	// EOF while a plain curl to the identical endpoint returns 200 with a real token
	// at the same second (pod Ready, no restart). Curl is the proven-reliable path.
	out, err := exec.CommandContext(ctx, "curl", "-s", "-k", "--max-time", "30", "-X", "POST",
		"-u", params.User+":"+params.Pwd, url).Output()
	if err != nil {
		log.Error("failed to get token", zap.Error(err), zap.String("response", string(out)))
		return "", err
	}

	result := struct {
		Token string `json:"token"`
	}{}
	if err := json.Unmarshal(out, &result); err != nil {
		log.Error("failed to parse token response", zap.Error(err), zap.String("response", string(out)))
		return "", err
	}
	if result.Token == "" {
		return "", fmt.Errorf("empty token; response: %s", string(out))
	}
	log.Info("token", zap.String("token", result.Token))
	return result.Token, nil
}
