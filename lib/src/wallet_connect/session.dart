import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:protobuf/protobuf.dart';
import 'package:provenance_dart/proto.dart' as proto;
import 'package:provenance_dart/src/proto/proto_gen/google/protobuf/any.pb.dart';
import 'package:provenance_dart/src/wallet/encoding/encoding.dart';
import 'package:provenance_dart/src/wallet_connect/encrypted_payload_helper.dart';
import 'package:provenance_dart/src/wallet_connect/messages.dart';
import 'package:provenance_dart/src/wallet_connect/relay.dart';
import 'package:provenance_dart/wallet_connect.dart';
import 'package:uuid/uuid.dart';

import '../../wallet.dart';

const uuid = Uuid();

class Base64UrlEncoder extends Converter<List<int>, String> {
  Base64UrlEncoder();

  final _base64Encoder = const Base64Encoder.urlSafe();
  final _regex = RegExp(r'^([^=]+)=*$');

  @override
  String convert(List<int> input) {
    final s = _base64Encoder.convert(input);
    return s.replaceAllMapped(_regex, (m) => m.group(1) ?? "");
  }
}

enum WalletConnectState { connecting, connected, disconnected }

class SessionRequestData {
  final String peerId;
  final String remotePeerId;
  final ClientMeta clientMeta;
  final WalletConnectAddress address;

  SessionRequestData(
    this.peerId,
    this.remotePeerId,
    this.clientMeta,
    this.address,
  );
}

class RepresentedPolicy {
  RepresentedPolicy({
    required this.groupId,
    required this.metadata,
    required this.address,
    required this.admin,
    required this.version,
    required this.createdAt,
    required this.decisionPolicy,
  });

  factory RepresentedPolicy.fromJson(Map<String, dynamic> json) {
    final createdAt = json['createdAt'];
    final decisionPolicy = json['decisionPolicy'];

    return RepresentedPolicy(
      groupId: json['groupId'],
      metadata: json['metadata'],
      address: json['address'],
      admin: json['admin'],
      version: json['version'],
      createdAt: DateTime.parse(createdAt),
      decisionPolicy: DecisionPolicy.fromJson(decisionPolicy),
    );
  }

  final int groupId;
  final String address;
  final String admin;
  final int version;
  final DateTime createdAt;
  final String? metadata;
  final DecisionPolicy decisionPolicy;

  Map<String, dynamic> toJson() {
    return {
      "decisionPolicy": decisionPolicy.toJson(),
      "groupId": groupId,
      "metadata": metadata,
      "address": address,
      "admin": admin,
      "version": version,
      "createdAt": createdAt.toIso8601String(),
    };
  }
}

class DecisionPolicy {
  DecisionPolicy({
    required this.typeUrl,
    required this.value,
  });

  factory DecisionPolicy.fromJson(Map<String, dynamic> json) {
    return DecisionPolicy(typeUrl: json['typeUrl'], value: json['value']);
  }

  final String typeUrl;
  final String value;

  Map<String, dynamic> toJson() {
    return {
      "typeUrl": typeUrl,
      "value": value,
    };
  }
}

class SessionApprovalData {
  final PrivateKey sessionSigningKey;
  final IPubKey accountPublicKey;
  final String chainId;
  final WalletInfo walletInfo;
  final RepresentedPolicy? representedPolicy;

  SessionApprovalData(this.sessionSigningKey, this.accountPublicKey,
      this.chainId, this.walletInfo,
      {this.representedPolicy});
}

class AccountInfo implements JsonEncodable {
  final String publicKey;
  final String address;
  final String jwt;
  final WalletInfo walletInfo;
  final RepresentedPolicy? representedGroupPolicy;

  AccountInfo(this.publicKey, this.address, this.jwt, this.walletInfo,
      this.representedGroupPolicy);

  factory AccountInfo.fromJson(Map<String, dynamic> json) {
    final walletInfo = json['walletInfo'];
    final representedGroupPolicy = json['representedGroupPolicy'];

    return AccountInfo(
      json['publicKey'],
      json['address'],
      json['jwt'],
      WalletInfo.fromJson(walletInfo),
      representedGroupPolicy != null
          ? RepresentedPolicy.fromJson(representedGroupPolicy)
          : null,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "publicKey": publicKey,
      "address": address,
      "jwt": jwt,
      "walletInfo": walletInfo.toJson(),
      "representedGroupPolicy": representedGroupPolicy?.toJson()
    };
  }
}

class WalletInfo implements JsonEncodable {
  final String id;
  final String name;
  final Coin coin;

  WalletInfo(this.id, this.name, this.coin);

  factory WalletInfo.fromJson(Map<String, dynamic> json) {
    final coinString = json['coin'];
    final coin = Coin.values.firstWhere((c) => c.name == coinString);

    return WalletInfo(json['id'], json['name'], coin);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "id": id,
      "name": name,
      "coin": coin.name,
    };
  }
}

class SessionRestoreData {
  final PrivateKey sessionSigningKey;
  final String chainId;
  final String peerId;
  final String remotePeerId;

  SessionRestoreData(
    this.sessionSigningKey,
    this.chainId,
    this.peerId,
    this.remotePeerId,
  );
}

class WalletConnectException implements Exception {
  final String message;
  final StackTrace? stackTrace;

  WalletConnectException(
    this.message, [
    this.stackTrace,
  ]);

  @override
  String toString() => '$message\n$stackTrace';
}

class SignTransactionData {
  SignTransactionData(
    this.proposedMessages,
    this.gasEstimate, {
    this.feeGranter,
    this.feePayer,
    this.memo,
    this.timeoutHeight,
    List<String>? nonCriticalExtensionOptions,
    List<String>? extensionOptions,
  })  : nonCriticalExtensionOptions = (nonCriticalExtensionOptions != null)
            ? List.unmodifiable(nonCriticalExtensionOptions)
            : null,
        extensionOptions = (extensionOptions != null)
            ? List.unmodifiable(extensionOptions)
            : null;

  final List<GeneratedMessage> proposedMessages;
  final proto.Coin? gasEstimate;
  final String? feeGranter;
  final String? feePayer;
  final String? memo;
  final int? timeoutHeight;
  // These are base64 encoded messages
  final List<String>? nonCriticalExtensionOptions;
  final List<String>? extensionOptions;
}

abstract class WalletConnectionDelegate {
  void onApproveSign(
      int requestId, String description, String address, List<int> msg);

  void onApproveTransaction(int requestId, String description, String address,
      SignTransactionData signTransactionData);

  void onApproveSession(int requestId, SessionRequestData data);

  void onError(Exception exception);

  void onClose();

  void onSessionCreated() {}
}

class WalletConnectionSessionClosedException implements Exception {
  @override
  String toString() => "The wallet connect session has been closed";
}

class WalletConnection extends ValueListenable<WalletConnectState>
    implements RelayDelegate {
  final List<VoidCallback> _listeners = <VoidCallback>[];
  final WalletConnectAddress address;
  final EncryptedPayloadHelper _encryptedPayloadHelper;
  final Map<dynamic, Completer> _responseLookup = <dynamic, Completer>{};

  WalletConnectState _status = WalletConnectState.disconnected;
  WalletConnectionDelegate? _delegate;
  PrivateKey? _sessionSigningKey;
  String? _chainId;
  WalletInfo? _walletInfo;
  String? _peerId;
  String? _remotePeerId;
  Relay? _relay;

  final ClientMeta? _clientMeta;

  ClientMeta? remoteClientMeta;
  AccountInfo? remoteAccountInfo;

  WalletConnection._(this.address, this._clientMeta)
      : _encryptedPayloadHelper =
            EncryptedPayloadHelper(Encoding.fromHex(address.key));

  WalletConnection(WalletConnectAddress address) : this._(address, null);

  factory WalletConnection.createSession(Uri bridgeUri, ClientMeta clientMeta) {
    final topic = uuid.v1().toString();
    final key =
        List.generate(32, (index) => math.Random().nextInt(255)).toList();

    final address = WalletConnectAddress(
      topic,
      1,
      bridgeUri,
      Encoding.toHex(key),
    );

    final connection = WalletConnection._(address, clientMeta);
    connection._peerId = uuid.v1().toString();
    return connection;
  }

  Future<void> connect(
    WalletConnectionDelegate delegate, [
    SessionRestoreData? restoreData,
  ]) async {
    if (_relay != null) {
      return Future.value();
    }

    try {
      _delegate = delegate;
      final peerId = restoreData?.peerId ?? uuid.v1().toString();
      _peerId = peerId;
      _remotePeerId = restoreData?.remotePeerId;
      _chainId = restoreData?.chainId;
      _sessionSigningKey = restoreData?.sessionSigningKey;

      _updateStatus(WalletConnectState.connecting);

      final webSocket = await WebSocket.connect(address.bridge.toString());
      webSocket.pingInterval = const Duration(seconds: 5);

      _relay = Relay(webSocket, _encryptedPayloadHelper, this);
      if (_clientMeta == null) {
        await Future.value([
          _relay!.subscribe(address.topic),
          _relay!.subscribe(peerId),
        ]);
      } else {
        await Future.value([
          _relay!.subscribe(_peerId!),
        ]);

        _requestSession().then((response) {
          if (!response.approved) {
            close();
          } else {
            _remotePeerId = response.peerId;
            remoteAccountInfo = response.accounts;
            remoteClientMeta = response.clientMeta;
            _delegate!.onSessionCreated();
          }
        }).catchError((err) {
          print(err.toString());
        });
      }
      _updateStatus(WalletConnectState.connected);
    } catch (e) {
      _delegate = null;
      _updateStatus(WalletConnectState.disconnected);
      rethrow;
    }
  }

  Future<List<int>> sendSignRequest(
      List<int> message, String description) async {
    final request = JsonRequest.provenanceSign(
        message, description, remoteAccountInfo!.address);

    final completer = Completer<String>();
    _responseLookup[request.id] = completer;

    await _relay!.publish(_remotePeerId!, request);

    return completer.future.then((hexString) => Encoding.fromHex(hexString));
  }

  Future<String> sendTransactionRequest(
    List<GeneratedMessage> messages,
    String description, {
    proto.Coin? gasEstimate,
    String? feeGranter,
    String? feePayer,
    String? memo,
    int? timeoutHeight,
    List<proto.GeneratedMessage>? nonCriticalExtensionOptions,
    List<proto.GeneratedMessage>? extensionOptions,
  }) async {
    final request = JsonRequest.sendTransaction(
      messages,
      description,
      remoteAccountInfo!.address,
      feeGranter: feeGranter,
      feePayer: feePayer,
      gasEstimate: gasEstimate,
      memo: memo,
      timeoutHeight: timeoutHeight,
      nonCriticalExtensionOptions: nonCriticalExtensionOptions
          ?.map((e) => base64Encode(e.toAny().writeToBuffer()))
          .toList(),
      extensionOptions: extensionOptions
          ?.map((e) => base64Encode(e.toAny().writeToBuffer()))
          .toList(),
    );

    final completer = Completer<String>();
    _responseLookup[request.id] = completer;

    await _relay!.publish(_remotePeerId!, request);

    return completer.future;
  }

  void _handleError(dynamic error) {
    Exception exception;
    if (error is Exception) {
      exception = error;
    } else if (error is Error) {
      exception = WalletConnectException(
        error.toString(),
        error.stackTrace,
      );
    } else {
      exception = WalletConnectException(
        error.toString(),
      );
    }
    _delegate?.onError(exception);
  }

  void _handleDone() {
    _delegate = null;
    _relay = null;
    _sessionSigningKey = null;
    _chainId = null;
    _updateStatus(WalletConnectState.disconnected);
  }

  Future<void> dispose() async {
    return _relay?.close();
  }

  Future<SessionApproval> _requestSession() async {
    final sessionRequest =
        SessionRequest(clientMeta: _clientMeta!, peerId: _peerId!);
    final request = JsonRequest.sessionApproval(sessionRequest);

    final completer = Completer<Map<String, dynamic>>();
    _responseLookup[request.id] = completer;

    await _relay!.publish(address.topic, request);

    return completer.future.then((json) => SessionApproval.fromJson(json));
  }

  void _processRequest(JsonRequest jsonRequest) {
    switch (jsonRequest.method) {
      case "wc_sessionRequest":
        _handleSessionRequest(jsonRequest)
            .onError((error, _) => _handleRequestErrors(error, jsonRequest.id));
        break;
      case "provenance_sign":
        _handleProvenanceSign(jsonRequest)
            .onError((error, _) => _handleRequestErrors(error, jsonRequest.id));
        break;
      case "provenance_sendTransaction":
        _handlerSendTransaction(jsonRequest)
            .onError((error, _) => _handleRequestErrors(error, jsonRequest.id));
        break;
      case "wc_sessionUpdate":
        _handleUpdateSession(jsonRequest)
            .onError((error, _) => _handleRequestErrors(error, jsonRequest.id));
        break;
      default:
        log("Unknown request method: ${jsonRequest.method}");
        final response = JsonRpcResponse.methodNotFound(jsonRequest.id);
        _relay?.respond(_remotePeerId!, response);
        break;
    }
  }

  void _handleRequestErrors(Object? error, int requestId) {
    final response = JsonRpcResponse.error(
        requestId, error?.toString() ?? "Internal error", -32603);
    _relay?.respond(_remotePeerId!, response);
  }

  Future<SessionRestoreData?> close() async {
    SessionRestoreData? restoreData;
    if (!(_remotePeerId == null ||
        _sessionSigningKey == null ||
        _chainId == null ||
        _peerId == null)) {
      restoreData = SessionRestoreData(
        _sessionSigningKey!,
        _chainId!,
        _peerId!,
        _remotePeerId!,
      );
    }

    await _relay!.close();
    _relay = null;
    return restoreData;
  }

  Future<void> disconnect() async {
    if (_remotePeerId != null) {
      final result = <String, dynamic>{
        "approved": false,
        "chainId": null,
        "accounts": null
      };

      final response = JsonRequest("wc_sessionUpdate", [result]);
      await _relay?.publish(_remotePeerId!, response);
    }
    await _relay?.close();
    _relay = null;

    // close out an existing futures.
    final pendingCompleters =
        List<Completer<dynamic>>.from(_responseLookup.values);
    _responseLookup.clear();

    for (final completer in pendingCompleters) {
      completer.completeError(WalletConnectionSessionClosedException());
    }
  }

  Future<void> _handleUpdateSession(JsonRequest request) async {
    final param = request.params.first;

    final approved = param['approved'];

    if (approved != null && !approved) {
      _relay?.close();
      _delegate?.onClose();
      _updateStatus(WalletConnectState.disconnected);
    }
  }

  Future<void> sendError(int requestId, String error) async {
    final response = JsonRpcResponse.error(requestId, error, -32010);
    await _relay?.respond(_remotePeerId!, response);
  }

  Future<void> reject(int requestId) async {
    final response = JsonRpcResponse.reject(requestId);
    await _relay?.respond(_remotePeerId!, response);
  }

  Future<void> sendTransactionResult(
      int requestId, proto.RawTxResponsePair txResponsePair) async {
    JsonRpcResponse response =
        JsonRpcResponse.sendTransaction(requestId, txResponsePair);

    await _relay!.respond(_remotePeerId!, response);
  }

  Future<void> sendSignResult(int requestId, List<int> signedData) async {
    final result = Encoding.toHex(signedData);
    final response = JsonRpcResponse.response(requestId, result);

    await _relay?.respond(_remotePeerId!, response);
  }

  Future<void> sendMultiSigSignResult(
      int requestId, List<AminoSignature> signatures) async {
    final result = signatures
        .map((e) => <String, dynamic>{
              "address": e.address,
              "signedData": Encoding.toHex(e.signedData),
            })
        .toList();

    final response = JsonRpcResponse.response(requestId, result);

    await _relay?.respond(_remotePeerId!, response);
  }

  Future<void> sendApproveSession(
      int requestId, SessionApprovalData sessionApprovalData,
      [ClientMeta? peerMeta]) async {
    _chainId = sessionApprovalData.chainId;
    _sessionSigningKey = sessionApprovalData.sessionSigningKey;
    _walletInfo = sessionApprovalData.walletInfo;

    final signingKey = _sessionSigningKey!;
    final publicKey = signingKey.publicKey;
    final pubKey = base64Encode(publicKey.compressedPublicKey);
    final authJwt = AuthorizationJwt().build(_sessionSigningKey!);

    final accountInfo = AccountInfo(
      pubKey,
      sessionApprovalData.accountPublicKey.address,
      authJwt,
      _walletInfo!,
      sessionApprovalData.representedPolicy,
    );
    final sessionApproval = SessionApproval.approve(
        peerMeta, _peerId!, _chainId!, accountInfo, null);

    final response = JsonRpcResponse.response(requestId, sessionApproval);
    await _relay!.respond(_remotePeerId!, response);
  }

  Future<void> sendRejectSession(int requestId) async {
    final sessionRejection = SessionApproval.reject();

    final response = JsonRpcResponse.response(requestId, sessionRejection);
    await _relay!.respond(_remotePeerId!, response);
  }

  Future<void> _handlerSendTransaction(JsonRequest request) async {
    final descriptionJson = jsonDecode(request.params.first as String);
    final messages = <GeneratedMessage>[];

    for (var index = 1; index < request.params.length; index++) {
      final payload = request.params[index];

      final bytes = Encoding.fromHex(payload.replaceFirst(RegExp(r'^0x'), ""));
      final json = base64Decode(utf8.decode(bytes));

      final protoAny = Any.fromBuffer(json);
      GeneratedMessage message = protoAny.toMessage();
      messages.add(message);
    }

    proto.Coin? gasEstimate;
    final jsonGas = descriptionJson['gasPrice'] as Map<String, dynamic>?;
    if (jsonGas != null && jsonGas.isNotEmpty) {
      gasEstimate = proto.Coin(
        amount: jsonGas["gasPrice"].toString(),
        denom: jsonGas['gasPriceDenom'],
      );
    }

    final description = descriptionJson['description'];
    final address = descriptionJson['address'];
    final feeGranter = (descriptionJson['feeGranter']?.isNotEmpty ?? false)
        ? descriptionJson['feeGranter']
        : null;
    final feePayer = (descriptionJson['feePayer']?.isNotEmpty ?? false)
        ? descriptionJson['feePayer']
        : null;
    final memo = (descriptionJson['memo']?.isNotEmpty ?? false)
        ? descriptionJson['memo']
        : null;
    final timeoutHeight = descriptionJson['timeoutHeight'];

    final signTransactionData = SignTransactionData(
      messages,
      gasEstimate,
      feeGranter: feeGranter,
      feePayer: feePayer,
      memo: memo,
      timeoutHeight: timeoutHeight,
      nonCriticalExtensionOptions:
          descriptionJson['nonCriticalExtensionOptions']?.cast<String>(),
      extensionOptions: descriptionJson['extensionOptions']?.cast<String>(),
    );
    _delegate?.onApproveTransaction(
        request.id, description, address, signTransactionData);
  }

  Future<void> _handleProvenanceSign(JsonRequest request) async {
    final descriptionJson = jsonDecode(request.params.first as String);
    final payload = request.params.last as String;
    final bytes = Encoding.fromHex(payload.replaceFirst(RegExp(r'^0x'), ""));

    final description = descriptionJson['description'];
    final address = descriptionJson['address'];

    _delegate?.onApproveSign(request.id, description, address, bytes);
  }

  Future<void> _handleSessionRequest(JsonRequest request) async {
    final param = request.params.first;
    _remotePeerId = param['peerId'];
    final peerMeta = param['peerMeta'];

    final clientMeta = ClientMeta.fromJson(peerMeta);

    final data = SessionRequestData(
      _peerId!,
      _remotePeerId!,
      clientMeta,
      address,
    );

    _delegate?.onApproveSession(request.id, data);
  }

  void _updateStatus(WalletConnectState status) {
    if (status == _status) {
      return;
    }
    _status = status;
    for (var listener in _listeners.toList()) {
      listener();
    }
  }

  /* ValueListenable */
  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  @override
  WalletConnectState get value => _status;

  /* RelayDelegate */
  @override
  void onJsonRpc(String topic, JsonRpcBase jsonRpc) {
    if (jsonRpc is JsonRequest) {
      _processRequest(jsonRpc);
    } else if (jsonRpc is JsonRpcResponse) {
      final completer = _responseLookup.remove(jsonRpc.id);
      if (jsonRpc.error != null) {
        completer?.completeError(jsonRpc.error!);
      } else {
        completer?.complete(jsonRpc.result);
      }
    }
  }

  @override
  void onStatusUpdated(RelayStatus relayStatus) {
    if (relayStatus == RelayStatus.connected) {
      _updateStatus(WalletConnectState.connected);
    } else if (relayStatus == RelayStatus.disconnected) {
      _updateStatus(WalletConnectState.disconnected);
    }
  }

  @override
  void onSubscribe(String subscribedTopic) {}

  @override
  void onError(Exception error) {
    _handleError(error);
  }
}
