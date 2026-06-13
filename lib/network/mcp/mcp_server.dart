/*
 * Copyright 2026 Antigravity. All rights reserved.
 */

import 'dart:convert';
import 'dart:io' as io;
import 'dart:async';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/components/manager/hosts_manager.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/configuration.dart';

/// 专门捕捉内存请求的事件监听器，专供 MCP 使用
class McpEventListener extends EventListener {
  static final McpEventListener instance = McpEventListener();

  final List<HttpRequest> _requests = [];
  static const int maxMemoryRequests = 200;

  List<HttpRequest> get requests => _requests;

  @override
  void onRequest(Channel channel, HttpRequest request) {
    if (_requests.length >= maxMemoryRequests) {
      _requests.removeAt(0);
    }
    _requests.add(request);
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {
    // 代理完成响应后，会自动在对应 request 实例上填充 response 属性。
    // 在这里我们可以做必要的数据刷新通知（如有需要）
  }

  void clear() {
    _requests.clear();
  }
}

/// Dart 原生的 HTTP JSON-RPC MCP 服务
class McpServer {
  static final McpServer instance = McpServer._();
  McpServer._();

  io.HttpServer? _server;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// 启动 MCP 服务
  Future<void> start(int port, String token) async {
    if (_isRunning) await stop();

    try {
      _server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, port);
      _isRunning = true;
      logger.i("[MCP Server] 启动成功，侦听端口: $port");

      // 注册事件监听器，捕获内存流量
      ProxyServer.current?.addListener(McpEventListener.instance);

      _server!.listen((io.HttpRequest request) async {
        // 设置跨域 CORS 头部
        request.response.headers.add("Access-Control-Allow-Origin", "*");
        request.response.headers.add("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        request.response.headers.add("Access-Control-Allow-Headers", "Content-Type, Authorization");

        if (request.method == "OPTIONS") {
          request.response.statusCode = io.HttpStatus.noContent;
          await request.response.close();
          return;
        }

        if (request.uri.path != "/mcp") {
          request.response.statusCode = io.HttpStatus.notFound;
          await request.response.close();
          return;
        }

        // 验证 Token 鉴权
        final authHeader = request.headers.value(io.HttpHeaders.authorizationHeader);
        if (authHeader != "Bearer $token") {
          request.response.statusCode = io.HttpStatus.unauthorized;
          request.response.headers.contentType = io.ContentType.json;
          request.response.write(jsonEncode({
            "jsonrpc": "2.0",
            "error": {"code": -32001, "message": "Unauthorized: 鉴权无效或 Token 缺失"}
          }));
          await request.response.close();
          return;
        }

        if (request.method != "POST") {
          request.response.statusCode = io.HttpStatus.methodNotAllowed;
          await request.response.close();
          return;
        }

        // 读取 POST body
        try {
          final bodyBytes = await request.fold<List<int>>([], (prev, element) => prev..addAll(element));
          final bodyString = utf8.decode(bodyBytes);
          if (bodyString.isEmpty) throw const FormatException("Empty body");

          final jsonRequest = jsonDecode(bodyString);
          final response = await _handleJsonRpc(jsonRequest);
          
          request.response.statusCode = io.HttpStatus.ok;
          if (response != null) {
            request.response.headers.contentType = io.ContentType.json;
            request.response.write(jsonEncode(response));
          }
        } catch (e) {
          request.response.statusCode = io.HttpStatus.badRequest;
          request.response.headers.contentType = io.ContentType.json;
          request.response.write(jsonEncode({
            "jsonrpc": "2.0",
            "error": {"code": -32700, "message": "Parse error: $e"}
          }));
        } finally {
          await request.response.close();
        }
      });
    } catch (e, st) {
      logger.e("[MCP Server] 启动失败", error: e, stackTrace: st);
    }
  }

  /// 停止 MCP 服务
  Future<void> stop() async {
    if (!_isRunning) return;
    
    // 移除监听器
    ProxyServer.current?.listeners.remove(McpEventListener.instance);
    McpEventListener.instance.clear();

    await _server?.close(force: true);
    _server = null;
    _isRunning = false;
    logger.i("[MCP Server] 已停止");
  }

  /// 处理 JSON-RPC 请求并分配路由
  Future<Map<String, dynamic>?> _handleJsonRpc(dynamic rpc) async {
    final id = rpc is Map ? rpc["id"] : null;
    final method = rpc is Map ? rpc["method"] : null;
    final params = rpc is Map ? rpc["params"] ?? {} : {};

    if (method == null) {
      return _makeError(id, -32600, "Invalid Request: method 缺失");
    }

    try {
      switch (method) {
        case "initialize":
          return {
            "jsonrpc": "2.0",
            "result": {
              "protocolVersion": params["protocolVersion"] ?? "2024-11-05",
              "capabilities": {
                "tools": {}
              },
              "serverInfo": {
                "name": "proxypin",
                "version": "1.0.0"
              }
            },
            "id": id
          };
        case "notifications/initialized":
          return null;
        case "tools/list":
          return {
            "jsonrpc": "2.0",
            "result": {
              "tools": _getToolsSchema()
            },
            "id": id
          };
        case "tools/call":
          final name = params["name"];
          final args = params["arguments"] ?? {};
          if (name == null) {
            return _makeError(id, -32602, "Invalid params: name 缺失");
          }
          final toolResult = await _executeTool(name, args);
          return {
            "jsonrpc": "2.0",
            "result": toolResult,
            "id": id
          };
        default:
          return _makeError(id, -32601, "Method not found: 未知方法 $method");
      }
    } catch (e, st) {
      logger.e("[MCP Server] 执行 $method 发生异常", error: e, stackTrace: st);
      return _makeError(id, -32000, "Internal error: $e");
    }
  }

  Map<String, dynamic> _makeError(dynamic id, int code, String message) {
    return {
      "jsonrpc": "2.0",
      "error": {"code": code, "message": message},
      "id": id
    };
  }

  /// 定义所暴露 Caucasian MCP 工具的 Schema
  List<Map<String, dynamic>> _getToolsSchema() {
    return [
      {
        "name": "mcp_list_requests",
        "description": "获取抓包请求列表简要信息（包含 ID, Method, URL, StatusCode 等）。支持通过域名/关键字过滤噪点。为了控制大模型上下文，此列表不输出 Payload 内容。",
        "inputSchema": {
          "type": "object",
          "properties": {
            "limit": {
              "type": "number",
              "description": "最大返回记录数，默认 50，最大 200"
            },
            "keyword": {
              "type": "string",
              "description": "可选。按 URL/域名 关键字过滤列表"
            },
            "source": {
              "type": "string",
              "enum": ["current", "history"],
              "description": "数据源：'current' 代表当前正在抓包的内存数据，'history' 代表历史抓包文件"
            },
            "historyIndex": {
              "type": "number",
              "description": "可选。当 source 为 history 时使用，代表历史会话的序号，若不传则默认使用最新一份历史"
            }
          }
        }
      },
      {
        "name": "mcp_get_request_detail",
        "description": "根据请求唯一 ID (requestId) 调取该包的完整详细报文。包含 Headers 及解码后的 Body 字符串。超长 Payload 会被自动截短。",
        "inputSchema": {
          "type": "object",
          "properties": {
            "requestId": {
              "type": "string",
              "description": "请求唯一 ID"
            },
            "source": {
              "type": "string",
              "enum": ["current", "history"],
              "description": "数据源：'current' 或 'history'"
            },
            "historyIndex": {
              "type": "number",
              "description": "可选。历史会话序号"
            }
          },
          "required": ["requestId"]
        }
      },
      {
        "name": "mcp_list_histories",
        "description": "列出在 Proxypin 本地已经保存的所有历史抓包会话 HAR 文件，包含文件名称、存储路径、抓包条数及大小。",
        "inputSchema": {
          "type": "object",
          "properties": {}
        }
      },
      {
        "name": "mcp_replay_request",
        "description": "变造并重新发起特定的 HTTP 请求，并回传最新响应。可在重放时修改请求头或请求体，用于逆向调试与漏洞探测。",
        "inputSchema": {
          "type": "object",
          "properties": {
            "requestId": {
              "type": "string",
              "description": "被模板请求的 ID"
            },
            "source": {
              "type": "string",
              "enum": ["current", "history"],
              "description": "数据源：'current' 或 'history'"
            },
            "historyIndex": {
              "type": "number",
              "description": "可选。历史会话序号"
            },
            "modifiedHeaders": {
              "type": "object",
              "description": "可选。修改或新增的请求头，例如 {\"Content-Type\": \"application/json\", \"X-Sign\": \"xxx\"}"
            },
            "modifiedBody": {
              "type": "string",
              "description": "可选。修改后的请求体 Payload 文本"
            }
          },
          "required": ["requestId"]
        }
      },
      {
        "name": "mcp_add_rewrite_rule",
        "description": "为特定匹配 URL 添加请求或响应重写规则。支持重定向、Mock 返回包、篡改 Header 或 Body 等。",
        "inputSchema": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "规则名称，如 'Mock Login'"
            },
            "urlPattern": {
              "type": "string",
              "description": "匹配 URL 模式，支持 '*' 通配符，例如 'https://api.test.com/v1/*'"
            },
            "action": {
              "type": "string",
              "enum": ["redirect", "requestReplace", "responseReplace", "requestUpdate", "responseUpdate"],
              "description": "重写动作类型"
            },
            "rewriteItems": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "type": {
                    "type": "string",
                    "description": "操作细节类型，如 'replaceResponseBody' 或 'replaceRequestHeader'"
                  },
                  "enabled": {
                    "type": "boolean"
                  },
                  "values": {
                    "type": "object",
                    "description": "规则所需映射，如 {\"body\": \"new JSON...\"} 或 {\"headers\": {\"Key\": \"Value\"}}"
                  }
                },
                "required": ["type", "enabled"]
              },
              "description": "重写细项列表"
            }
          },
          "required": ["name", "urlPattern", "action", "rewriteItems"]
        }
      },
      {
        "name": "mcp_add_script_rule",
        "description": "为特定匹配 URL 注入 JavaScript 执行脚本，可在网络层面动态拦截、计算签名、数据脱密等。",
        "inputSchema": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "脚本项目名称"
            },
            "urlPattern": {
              "type": "string",
              "description": "匹配 URL 规则，如 'https://api.test.com/*'"
            },
            "scriptContent": {
              "type": "string",
              "description": "JavaScript 执行脚本，包含异步的 onRequest(context, request) 和 onResponse(context, request, response) 接口"
            }
          },
          "required": ["name", "urlPattern", "scriptContent"]
        }
      },
      {
        "name": "mcp_add_host_mapping",
        "description": "动态映射指定域名到新的 IP 地址（例如将生产环境 API 导向测试服IP），实现快捷 Host 配置。",
        "inputSchema": {
          "type": "object",
          "properties": {
            "domain": {
              "type": "string",
              "description": "要拦截的域名，支持通配符，如 '*.test.com'"
            },
            "ip": {
              "type": "string",
              "description": "目标 IP 地址，例如 '127.0.0.1'"
            }
          },
          "required": ["domain", "ip"]
        }
      },
      {
        "name": "mcp_add_block_rule",
        "description": "添加请求阻断/拦截屏蔽规则，自动丢弃/拦截特定不需要调试的高频心跳或广告打点接口。",
        "inputSchema": {
          "type": "object",
          "properties": {
            "urlPattern": {
              "type": "string",
              "description": "要阻断的 URL 模式，如 'https://ads.domain.com/*'"
            }
          },
          "required": ["urlPattern"]
        }
      },
      {
        "name": "mcp_get_server_status",
        "description": "获取 Proxypin 代理捕获核心的物理状态（端口、HTTPS SSL 拦截开关、运行中状态等）。",
        "inputSchema": {
          "type": "object",
          "properties": {}
        }
      },
      {
        "name": "mcp_toggle_server",
        "description": "启停或重启 Proxypin 的代理服务器物理端口捕获。",
        "inputSchema": {
          "type": "object",
          "properties": {
            "action": {
              "type": "string",
              "enum": ["start", "stop", "restart"],
              "description": "执行动作"
            }
          },
          "required": ["action"]
        }
      }
    ];
  }

  /// 统一工具执行路由
  Future<Map<String, dynamic>> _executeTool(String name, Map<String, dynamic> args) async {
    switch (name) {
      case "mcp_list_requests":
        return await _listRequests(args);
      case "mcp_get_request_detail":
        return await _getRequestDetail(args);
      case "mcp_list_histories":
        return await _listHistories(args);
      case "mcp_replay_request":
        return await _replayRequest(args);
      case "mcp_add_rewrite_rule":
        return await _addRewriteRule(args);
      case "mcp_add_script_rule":
        return await _addScriptRule(args);
      case "mcp_add_host_mapping":
        return await _addHostMapping(args);
      case "mcp_add_block_rule":
        return await _addBlockRule(args);
      case "mcp_get_server_status":
        return await _getServerStatus(args);
      case "mcp_toggle_server":
        return await _toggleServer(args);
      default:
        throw Exception("Unknown tool name: $name");
    }
  }

  // --- 工具细项具体实现 ---

  Future<Map<String, dynamic>> _listRequests(Map<String, dynamic> args) async {
    final limit = (args["limit"] as num?)?.toInt() ?? 50;
    final keyword = args["keyword"] as String?;
    final source = args["source"] as String? ?? "current";
    final historyIndex = (args["historyIndex"] as num?)?.toInt();

    List<HttpRequest> reqs = [];
    if (source == "current") {
      reqs = List.from(McpEventListener.instance.requests);
    } else {
      final storage = await HistoryStorage.instance;
      if (storage.histories.isNotEmpty) {
        final idx = historyIndex ?? (storage.histories.length - 1);
        if (idx >= 0 && idx < storage.histories.length) {
          reqs = await storage.getRequests(storage.getHistory(idx));
        }
      }
    }

    // 过滤与逆序
    var filtered = reqs.reversed.toList();
    if (keyword != null && keyword.trim().isNotEmpty) {
      filtered = filtered.where((r) => r.requestUrl.contains(keyword)).toList();
    }
    
    final resultList = filtered.take(limit).map((r) {
      return {
        "id": r.requestId,
        "method": r.method.name,
        "url": r.requestUrl,
        "statusCode": r.response?.status.code,
        "contentType": r.response?.headers.contentType,
        "time": r.requestId.hashCode // 标识时间
      };
    }).toList();

    return _makeTextResult(resultList);
  }

  Future<Map<String, dynamic>> _getRequestDetail(Map<String, dynamic> args) async {
    final requestId = args["requestId"] as String;
    final source = args["source"] as String? ?? "current";
    final historyIndex = (args["historyIndex"] as num?)?.toInt();

    List<HttpRequest> reqs = [];
    if (source == "current") {
      reqs = McpEventListener.instance.requests;
    } else {
      final storage = await HistoryStorage.instance;
      if (storage.histories.isNotEmpty) {
        final idx = historyIndex ?? (storage.histories.length - 1);
        if (idx >= 0 && idx < storage.histories.length) {
          reqs = await storage.getRequests(storage.getHistory(idx));
        }
      }
    }

    final req = reqs.firstWhere((r) => r.requestId == requestId, orElse: () => throw Exception("Request not found"));
    
    // 对 Body 字符大小做限额保护
    String? reqBody = req.bodyAsString;
    if (reqBody.length > 2000) {
      reqBody = "${reqBody.substring(0, 2000)}...\n[Body已被截短，如需查看全量，可通过特定参数获取]";
    }

    String? respBody = req.response?.bodyAsString;
    if (respBody != null && respBody.length > 2000) {
      respBody = "${respBody.substring(0, 2000)}...\n[Body已被截短]";
    }

    final detail = {
      "id": req.requestId,
      "url": req.requestUrl,
      "method": req.method.name,
      "requestHeaders": req.headers.toMap(),
      "requestBody": reqBody,
      "responseStatus": req.response?.status.code,
      "responseHeaders": req.response?.headers.toMap(),
      "responseBody": respBody
    };

    return _makeTextResult(detail);
  }

  Future<Map<String, dynamic>> _listHistories(Map<String, dynamic> args) async {
    final storage = await HistoryStorage.instance;
    final list = storage.histories.asMap().entries.map((entry) {
      final idx = entry.key;
      final item = entry.value;
      return {
        "index": idx,
        "name": item.name,
        "path": item.path,
        "requestLength": item.requestLength,
        "fileSize": item.fileSize
      };
    }).toList();

    return _makeTextResult(list);
  }

  Future<Map<String, dynamic>> _replayRequest(Map<String, dynamic> args) async {
    final requestId = args["requestId"] as String;
    final source = args["source"] as String? ?? "current";
    final historyIndex = (args["historyIndex"] as num?)?.toInt();
    final modifiedHeaders = args["modifiedHeaders"] as Map?;
    final modifiedBody = args["modifiedBody"] as String?;

    List<HttpRequest> reqs = [];
    if (source == "current") {
      reqs = McpEventListener.instance.requests;
    } else {
      final storage = await HistoryStorage.instance;
      if (storage.histories.isNotEmpty) {
        final idx = historyIndex ?? (storage.histories.length - 1);
        if (idx >= 0 && idx < storage.histories.length) {
          reqs = await storage.getRequests(storage.getHistory(idx));
        }
      }
    }

    final target = reqs.firstWhere((r) => r.requestId == requestId, orElse: () => throw Exception("Replay target not found"));
    
    // 拷贝原始请求
    final reReq = target.copy(uri: target.requestUrl);
    
    // 应用修改
    if (modifiedHeaders != null) {
      modifiedHeaders.forEach((key, val) {
        reReq.headers.set(key.toString(), val.toString());
      });
    }

    if (modifiedBody != null) {
      reReq.body = utf8.encode(modifiedBody);
    }

    final server = ProxyServer.current;
    final proxyInfo = (server != null && server.isRunning) ? ProxyInfo.of("127.0.0.1", server.port) : null;
    
    // 激活重放执行
    final response = await HttpClients.proxyRequest(reReq, proxyInfo: proxyInfo, timeout: const Duration(seconds: 15));
    
    final reDetail = {
      "status": response.status.code,
      "headers": response.headers.toMap(),
      "body": response.bodyAsString.length > 2000 ? "${response.bodyAsString.substring(0, 2000)}..." : response.bodyAsString
    };

    return _makeTextResult(reDetail);
  }

  Future<Map<String, dynamic>> _addRewriteRule(Map<String, dynamic> args) async {
    final name = args["name"] as String;
    final urlPattern = args["urlPattern"] as String;
    final action = args["action"] as String;
    final rawItems = args["rewriteItems"] as List;

    final rule = RequestRewriteRule(
      name: name,
      url: urlPattern,
      type: RuleType.fromName(action),
      enabled: true
    );

    final List<RewriteItem> items = rawItems.map((e) => RewriteItem.fromJson(e as Map)).toList();

    final manager = await RequestRewriteManager.instance;
    await manager.addRule(rule, items);
    await manager.flushRequestRewriteConfig();

    return _makeTextResult({"success": true, "ruleName": name});
  }

  Future<Map<String, dynamic>> _addScriptRule(Map<String, dynamic> args) async {
    final name = args["name"] as String;
    final urlPattern = args["urlPattern"] as String;
    final scriptContent = args["scriptContent"] as String;

    final item = ScriptItem(true, name, urlPattern);
    
    final manager = await ScriptManager.instance;
    await manager.addScript(item, scriptContent);

    return _makeTextResult({"success": true, "scriptName": name});
  }

  Future<Map<String, dynamic>> _addHostMapping(Map<String, dynamic> args) async {
    final domain = args["domain"] as String;
    final ip = args["ip"] as String;

    final item = HostsItem(host: domain, toAddress: ip, enabled: true);
    final manager = await HostsManager.instance;
    await manager.addHosts(item);
    await manager.flushConfig();

    return _makeTextResult({"success": true, "host": domain, "ip": ip});
  }

  Future<Map<String, dynamic>> _addBlockRule(Map<String, dynamic> args) async {
    final urlPattern = args["urlPattern"] as String;

    final item = RequestBlockItem(true, urlPattern, BlockType.blockRequest);
    final manager = await RequestBlockManager.instance;
    manager.addBlockRequest(item);

    return _makeTextResult({"success": true, "blockedPattern": urlPattern});
  }

  Future<Map<String, dynamic>> _getServerStatus(Map<String, dynamic> args) async {
    final server = ProxyServer.current;
    if (server == null) {
      return _makeTextResult({"isRunning": false, "message": "Server instance not created"});
    }

    return _makeTextResult({
      "isRunning": server.isRunning,
      "port": server.port,
      "enableSsl": server.enableSsl
    });
  }

  Future<Map<String, dynamic>> _toggleServer(Map<String, dynamic> args) async {
    final action = args["action"] as String;
    final server = ProxyServer.current;
    if (server == null) {
      throw Exception("Server instance not initialized");
    }

    if (action == "start") {
      if (!server.isRunning) await server.start();
    } else if (action == "stop") {
      if (server.isRunning) await server.stop();
    } else if (action == "restart") {
      await server.restart();
    }

    return _makeTextResult({
      "success": true,
      "isRunning": server.isRunning,
      "port": server.port
    });
  }

  Map<String, dynamic> _makeTextResult(dynamic data) {
    return {
      "content": [
        {
          "type": "text",
          "text": jsonEncode(data)
        }
      ]
    };
  }
}
