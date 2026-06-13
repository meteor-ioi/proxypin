/*
 * Copyright 2026 Antigravity. All rights reserved.
 */

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/component/ai_setting_dialog.dart';
import 'package:proxypin/ui/component/utils.dart';

class MessageItem {
  final String role; // 'user' 或 'assistant'
  String content;

  MessageItem(this.role, this.content);
}

// 全局缓存 AI 诊断的会话历史。Key 为 request.requestId
final Map<String, List<MessageItem>> _aiAnalysisCache = {};

class AiAnalysisPanel extends StatefulWidget {
  final HttpRequest request;
  final bool hideAppBar;

  const AiAnalysisPanel({super.key, required this.request, this.hideAppBar = false});

  @override
  State<AiAnalysisPanel> createState() => _AiAnalysisPanelState();
}

class _AiAnalysisPanelState extends State<AiAnalysisPanel> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isLoading = false;
  String? _error;

  List<MessageItem> get _messages {
    final rid = widget.request.requestId;
    if (!_aiAnalysisCache.containsKey(rid)) {
      return [];
    }
    return _aiAnalysisCache[rid]!;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _startAnalysis() {
    final rid = widget.request.requestId;
    if (_aiAnalysisCache.containsKey(rid)) return;
    
    _aiAnalysisCache[rid] = [];
    _initAnalysis();
  }

  Widget _buildIntroPanel() {
    final req = widget.request;
    final url = req.requestUrl;
    final method = req.method.name;
    final reqLen = req.body?.length ?? 0;
    final respLen = req.response?.body?.length ?? 0;
    
    final theme = Theme.of(context);
    
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.psychology, 
                size: 56, 
                color: theme.colorScheme.primary
              ),
            ),
            const SizedBox(height: 20),
            Text(
              "Proxypin AI 流量逆向诊断",
              style: TextStyle(
                fontSize: 18, 
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildIntroItem("请求方法", method, Colors.green),
                  const SizedBox(height: 8),
                  _buildIntroItem("请求地址", url, Colors.black87),
                  const SizedBox(height: 8),
                  _buildIntroItem("请求 Body 大小", getPackage(reqLen), Colors.blueGrey),
                  const SizedBox(height: 8),
                  _buildIntroItem("响应 Body 大小", getPackage(respLen), Colors.blueGrey),
                ],
              ),
            ),
            const SizedBox(height: 25),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                icon: const Icon(Icons.rocket_launch),
                label: const Text(
                  "开启 AI 流量智能诊断",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                onPressed: _startAnalysis,
              ),
            ),
            const SizedBox(height: 15),
            Text(
              "* 诊断需要发送请求元数据与解码的 Payload，请确认已配置大模型 API Key。",
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroItem(String label, String value, Color valueColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: TextStyle(fontSize: 13, color: valueColor, fontFamily: 'monospace'),
        ),
      ],
    );
  }

  // 初始化分析 Prompt 并发起第一轮分析
  Future<void> _initAnalysis() async {
    final config = AppConfiguration.current;
    if (config == null || config.llmApiKey.isEmpty) {
      _aiAnalysisCache.remove(widget.request.requestId);
      setState(() {
        _error = "尚未配置 LLM 大模型。请先点击右上角齿轮图标配置 API Key 与服务地址。";
      });
      return;
    }

    final req = widget.request;
    String reqBody = req.bodyAsString;
    if (reqBody.length > 2500) {
      reqBody = "${reqBody.substring(0, 2500)}...\n[Body 已被部分截短]";
    }

    String? respBody = req.response?.bodyAsString;
    if (respBody != null && respBody.length > 2500) {
      respBody = "${respBody.substring(0, 2500)}...\n[Body 已被部分截短]";
    }

    // 构建上下文
    final systemPrompt = "你是一位资深的网络协议分析师和网络安全审计专家。我会向你提供一条被捕获的 HTTP/HTTPS 请求报文及响应报文。请你深度分析它，给出：\n"
        "1. 接口功能与用途推导\n"
        "2. 所有请求和响应参数的精准业务含义解读\n"
        "3. 是否存在越权漏洞、数据敏感泄露等安全隐患，以及接口中的参数签名校验机制\n"
        "4. 附上能够完美重现复现此接口调用的 Python requests 示例代码。\n"
        "请保持回答的技术客观性、条理性，回答使用简体中文，并以 Markdown 结构返回。";

    final userPrompt = "请求信息：\n"
        "- Method: ${req.method.name}\n"
        "- URL: ${req.requestUrl}\n"
        "- Request Headers: ${req.headers.toMap()}\n"
        "- Request Body: $reqBody\n\n"
        "响应信息：\n"
        "- Status Code: ${req.response?.status.code ?? '未知'}\n"
        "- Response Headers: ${req.response?.headers.toMap() ?? '无'}\n"
        "- Response Body: ${respBody ?? '无'}";

    setState(() {
      _messages.add(MessageItem("system", systemPrompt));
      _messages.add(MessageItem("user", userPrompt));
      _messages.add(MessageItem("assistant", "正在为您连接大模型并开启流量逆向分析，请稍后..."));
    });
    
    _scrollToBottom();
    _callLLM();
  }

  // 流式调用 LLM
  Future<void> _callLLM() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final config = AppConfiguration.current!;
    final url = Uri.parse("${config.llmBaseUrl}/chat/completions");
    final client = HttpClient();

    // 最后一项是我们的 assistant 初始提示占位符，用来流式渲染
    final activeMessage = _messages.last;
    activeMessage.content = "";

    try {
      final request = await client.postUrl(url);
      request.headers.set(HttpHeaders.contentTypeHeader, "application/json");
      request.headers.set(HttpHeaders.authorizationHeader, "Bearer ${config.llmApiKey}");

      final body = {
        "model": config.llmModel,
        "messages": _messages.sublist(0, _messages.length - 1).map((m) => {
          "role": m.role,
          "content": m.content
        }).toList(),
        "stream": true,
      };
      request.write(jsonEncode(body));

      final response = await request.close();
      if (response.statusCode != 200) {
        final errText = await response.transform(utf8.decoder).join();
        setState(() {
          _error = "API 请求失败 (状态码 ${response.statusCode}): $errText";
          activeMessage.content = "获取分析报告失败。";
        });
        return;
      }

      final lines = response.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        if (line.startsWith("data: ")) {
          final dataStr = line.substring(6).trim();
          if (dataStr == "[DONE]") break;
          try {
            final parsed = jsonDecode(dataStr);
            final delta = parsed["choices"]?[0]?["delta"]?["content"];
            if (delta != null) {
              setState(() {
                activeMessage.content += delta.toString();
              });
              _scrollToBottom();
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      setState(() {
        _error = "请求异常: $e";
        activeMessage.content = "连接大模型超时或遭遇异常。";
      });
    } finally {
      client.close();
      setState(() {
        _isLoading = false;
      });
      _scrollToBottom();
    }
  }

  // 发送追问
  void _sendMessage() {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isLoading) return;

    _inputController.clear();
    setState(() {
      _messages.add(MessageItem("user", text));
      _messages.add(MessageItem("assistant", "正在思考中..."));
    });
    _scrollToBottom();
    _callLLM();
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (context) => const AiSettingDialog(),
    ).then((_) {
      if (_error != null && AppConfiguration.current?.llmApiKey.isNotEmpty == true) {
        setState(() {
          _error = null;
        });
        _startAnalysis();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasStarted = _messages.isNotEmpty;
    // 隐藏 System Prompt 不向用户渲染，渲染时从 index=1 开始
    final visibleMessages = _messages.where((m) => m.role != "system").toList();

    return Scaffold(
      appBar: widget.hideAppBar ? null : AppBar(
        title: const Text("AI 流量逆向助手"),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: "配置大模型与 MCP",
            onPressed: _showSettings,
          )
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(10),
              color: Colors.red.shade50,
              width: double.infinity,
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                  ),
                  TextButton(
                    onPressed: _showSettings,
                    child: const Text("去配置"),
                  ),
                ],
              ),
            ),
          Expanded(
            child: !hasStarted
                ? _buildIntroPanel()
                : visibleMessages.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(15),
                        itemCount: visibleMessages.length,
                        itemBuilder: (context, index) {
                          final item = visibleMessages[index];
                          final isUser = item.role == "user";
                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  backgroundColor: isUser ? Colors.blue.shade100 : Colors.teal.shade100,
                                  radius: 16,
                                  child: Icon(
                                    isUser ? Icons.person : Icons.android,
                                    size: 18,
                                    color: isUser ? Colors.blue.shade900 : Colors.teal.shade900,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        isUser ? "You" : "AI Assistant",
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey),
                                      ),
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: isUser ? Colors.blue.shade50 : Colors.grey.shade100,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: SelectableText(
                                          item.content,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontFamily: !isUser ? 'monospace' : null,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
          if (hasStarted)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
                color: Colors.white,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      decoration: const InputDecoration(
                        hintText: "请输入追问内容，如：'解释一下参数 sign 的计算方式'...",
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.blue),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
