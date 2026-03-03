package steps

import (
	"context"

	"github.com/cucumber/godog"
)

// Steps provides Kubernetes resource management step definitions
type Steps struct {
}

// InitializeSteps registers resource assertion and import steps
func (cs Steps) InitializeSteps(ctx context.Context, scenarioCtx *godog.ScenarioContext) context.Context {
	scenarioCtx.Step(`^"([^"]*)" 实例资源检查通过$`, stepSonarqubeResourceConditionCheck)
	scenarioCtx.Step(`^SSO 测试通过$`, checkSSo)
	scenarioCtx.Step(`^SonarQube 分析通过$`, WaitForAnalysis)

	// RBAC permission test steps
	scenarioCtx.Step(`^创建 "([^"]*)" ServiceAccount 和 Token$`, stepCreateRBACUser)
	scenarioCtx.Step(`^使用 "([^"]*)" Token 创建 sonarqube 实例$`, stepCreateSonarqubeInstanceWithToken)
	scenarioCtx.Step(`^"([^"]*)" 应该能够创建 sonarqube 实例$`, stepShouldCreateInstance)
	scenarioCtx.Step(`^"([^"]*)" 不应该能够创建 sonarqube 实例$`, stepShouldNotCreateInstanceWithCheck)
	scenarioCtx.Step(`^"([^"]*)" 应该能够查看 sonarqube 实例$`, stepShouldViewInstance)
	scenarioCtx.Step(`^"([^"]*)" 应该能够更新 sonarqube 实例$`, stepShouldUpdateInstance)
	scenarioCtx.Step(`^"([^"]*)" 不应该能够更新 sonarqube 实例$`, stepShouldNotUpdateInstance)
	scenarioCtx.Step(`^"([^"]*)" 验证不能创建实例$`, stepShouldNotCreateInstance)

	return ctx
}
