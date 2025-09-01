# language: zh-CN

@e2e
@sonarqube-operator-deploy-use-mw-pg
功能: 使用数据服务的pg部署sonarqube


  @smoke
  @automated
  @priority-high
  @allure.label.case_id:sonarqube-operator-deploy-use-mw-pg
  场景: 使用数据服务的pg部署sonarqube
    假定 命名空间 "testing-sonarqube-mw-<template.{{randAlphaNum 4 | toLower}}>" 已存在
    并且 已导入 "SonarQube 自定义 root 密码" 资源: "./testdata/resources/custom-root-password.yaml"
    并且 已导入 "pg secret" 资源: "./testdata/resources/mw-pg-secret.yaml"
    并且 已导入 "database" 资源: "./testdata/resources/use-mw-pg-job-create-db.yaml"
    并且 已导入 "sonarqube实例" 资源: "./testdata/use-mw-pg-deploy-sonar.yaml"
    并且 "sonarqube" 可以正常访问
      """
      url: http://<node.ip.random.readable>:<nodeport.http>
      timeout: 30m
      """