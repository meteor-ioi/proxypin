#!/usr/bin/env node

/*
 * Copyright 2026 Antigravity. All rights reserved.
 * Stdio-to-HTTP Bridge for Proxypin MCP Server.
 */

const fs = require('fs');
const path = require('path');
const http = require('http');
const readline = require('readline');

// 默认配置
let port = 8899;
let token = '';

// 尝试自动读取本地 Proxypin 配置文件
try {
  const homeDir = process.env.HOME || process.env.USERPROFILE;
  const configPath = path.join(homeDir, '.proxypin', 'ui_config.json');
  if (fs.existsSync(configPath)) {
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    if (config.mcpPort) port = parseInt(config.mcpPort, 10);
    if (config.mcpToken) token = config.mcpToken;
  }
} catch (e) {
  // 忽略错误，回退到默认
}

// 支持命令行参数覆盖
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    port = parseInt(args[i + 1], 10);
    i++;
  } else if (args[i] === '--token' && args[i + 1]) {
    token = args[i + 1];
    i++;
  }
}

// 启动 Stdio 逐行读取
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

rl.on('line', (line) => {
  if (!line.trim()) return;

  const body = Buffer.from(line, 'utf8');

  // 转发 JSON-RPC 请求到本地 HTTP Server
  const options = {
    hostname: '127.0.0.1',
    port: port,
    path: '/mcp',
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`,
      'Content-Length': body.length
    }
  };

  const req = http.request(options, (res) => {
    let responseData = '';
    res.on('data', (chunk) => {
      responseData += chunk;
    });
    res.on('end', () => {
      // 写入到 stdout 给 AI 客户端
      process.stdout.write(responseData + '\n');
    });
  });

  req.on('error', (e) => {
    // 遇到连接错误，回传标准 JSON-RPC 错误以防 AI 客户端 Crash
    try {
      const parsed = JSON.parse(line);
      const errResponse = {
        jsonrpc: '2.0',
        error: { 
          code: -32603, 
          message: `无法连接到 Proxypin 后台服务 (Port ${port})，请确保 Proxypin 客户端已运行且开启了 MCP。错误: ${e.message}` 
        },
        id: parsed.id || null
      };
      process.stdout.write(JSON.stringify(errResponse) + '\n');
    } catch {
      // 忽略无法解析的请求
    }
  });

  req.write(body);
  req.end();
});
