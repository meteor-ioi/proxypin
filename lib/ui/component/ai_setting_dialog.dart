/*
 * Copyright 2026 Antigravity. All rights reserved.
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/network/mcp/mcp_server.dart';
import 'package:flutter_toastr/flutter_toastr.dart';

class AiSettingDialog extends StatefulWidget {
  const AiSettingDialog({super.key});

  @override
  State<AiSettingDialog> createState() => _AiSettingDialogState();
}

class _AiSettingDialogState extends State<AiSettingDialog> {
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _portController = TextEditingController();
  bool _mcpEnabled = false;
  String _mcpToken = "";

  @override
  void initState() {
    super.initState();
    final config = AppConfiguration.current;
    if (config != null) {
      _apiKeyController.text = config.llmApiKey;
      _baseUrlController.text = config.llmBaseUrl;
      _modelController.text = config.llmModel;
      _portController.text = config.mcpPort.toString();
      _mcpEnabled = config.mcpEnabled;
      _mcpToken = config.mcpToken;
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final config = AppConfiguration.current;
    if (config == null) return;

    final port = int.tryParse(_portController.text) ?? 8899;

    final prevEnabled = config.mcpEnabled;
    final prevPort = config.mcpPort;
    final prevToken = config.mcpToken;

    config.llmApiKey = _apiKeyController.text.trim();
    config.llmBaseUrl = _baseUrlController.text.trim();
    config.llmModel = _modelController.text.trim();
    config.mcpEnabled = _mcpEnabled;
    config.mcpPort = port;

    await config.flushConfig();

    // 根据开关状态和端口变化动态控制 MCP Server
    if (_mcpEnabled) {
      if (!prevEnabled || prevPort != port || prevToken != config.mcpToken || !McpServer.instance.isRunning) {
        await McpServer.instance.start(port, config.mcpToken);
      }
    } else {
      if (prevEnabled) {
        await McpServer.instance.stop();
      }
    }

    if (mounted) {
      FlutterToastr.show("AI 与 MCP 配置保存成功", context);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("AI 分析与 MCP 服务配置"),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("🤖 LLM 大模型配置", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 10),
              TextField(
                controller: _apiKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "API Key (如: sk-xxx)",
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _baseUrlController,
                decoration: const InputDecoration(
                  labelText: "API Base URL",
                  helperText: "例如: https://api.deepseek.com/v1 或 https://api.openai.com/v1",
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: "模型名称 (Model Name)",
                  helperText: "如: deepseek-chat 或 gpt-4o-mini",
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const Divider(height: 25),
              const Text("🔌 MCP 服务配置 (外部 AI 桥接)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 5),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text("启用内置 MCP 服务"),
                subtitle: Text(McpServer.instance.isRunning ? "状态: 运行中" : "状态: 未启动", 
                    style: TextStyle(color: McpServer.instance.isRunning ? Colors.green : Colors.grey)),
                value: _mcpEnabled,
                onChanged: (val) {
                  setState(() {
                    _mcpEnabled = val;
                  });
                },
              ),
              if (_mcpEnabled) ...[
                const SizedBox(height: 5),
                TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "MCP 侦听端口",
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text("安全鉴权 Token:\n$_mcpToken", style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      tooltip: "复制 Token",
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _mcpToken));
                        FlutterToastr.show("Token 已复制到剪贴板", context);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                const Text("说明: 外部 Agent (如 Cursor) 请配置 proxypin-mcp.js 脚本桥接以访问此实例。",
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("取消"),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text("保存"),
        ),
      ],
    );
  }
}
