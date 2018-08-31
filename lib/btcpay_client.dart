import "dart:io";
import "dart:core";
import "dart:async";
import "dart:convert";
import "dart:typed_data";

import 'package:convert/convert.dart';
import "package:base58check/base58.dart";
import "package:pointycastle/api.dart";
import "package:pointycastle/ecc/api.dart";
import "package:pointycastle/digests/sha256.dart";
import "package:pointycastle/digests/ripemd160.dart";

import "key_utils.dart";

class Client {
  const String userAgent = '{BTC|Bit}Pay - Dart';

  Uri url;
  AsymmetricKeyPair keyPair;
  HttpClient httpClient;
  String authorizationToken;

  const String tokenPath = 'tokens';
  const String apiAccessRequestPath = 'api-access-request';
  const String invoicesPath = 'invoices';

  /// clientId aka SIN
  String clientId;
  String identity;

  const String alphabet =
      "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  const int prefix = 0x0F;
  const int sinType = 0x02;

  static final ripemd160digest = RIPEMD160Digest();
  static final sha256digest = SHA256Digest();

  Client(String url, this.keyPair) {
    clientId = _convertToClientId(keyPair.publicKey);
    identity = hex.encoder
        .convert((keyPair.publicKey as ECPublicKey).Q.getEncoded(true));
    httpClient = HttpClient();
    this.url = Uri.parse(url);
  }

  /// Returns a URL to which the user must go to approve the pairing.
  String clientInitiatedPairing() async {
    var request = await _requestPairingCode();
    var response = await _doRequest(request);
    String pairingCode = response['data'][0]['pairingCode'];

    return url.replace(
      path: apiAccessRequestPath,
      queryParameters: {'pairingCode': pairingCode},
    ).toString();
  }

  /// Creates an invoice on the remote.
  Map<String, dynamic> createInvoice(double price, String currency) async {
    authorizationToken ??= await getToken();

    HttpClientRequest request = await httpClient
        .postUrl(url.replace(path: invoicesPath))
        .then((HttpClientRequest request) {
      Map<String, dynamic> params = {
        "token": authorizationToken,
        "id": clientId,
        "price": price,
        "currency": currency,
      };
      request.headers.set(
        'X-Signature',
        sign(request.uri.toString() + jsonEncode(params), keyPair.privateKey),
      );
      request.headers.set('X-Identity', identity);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(params));

      return request;
    });

    var body = await _doRequest(request);

    return body;
  }

  Map<String, dynamic> getInvoice(String id) async {
    var request = await httpClient
        .getUrl(url.replace(path: '$invoicesPath/$id'))
        .then((HttpClientRequest request) {
      request.headers.contentType = ContentType.json;

      return request;
    });

    var response = await _doRequest(request);

    return response;
  }

  /// Returns a token which is required to create a invoice.
  String getToken() async {
    // Annoyingly the Dart compiler doesn't correctly infer the sub type.
    ECPublicKey publicKey = keyPair.publicKey;
    var request = await httpClient.getUrl(url.replace(path: tokenPath));
    request.headers
        .set('X-Signature', sign(request.uri.toString(), keyPair.privateKey));
    request.headers.set('X-Identity', identity);

    var body = await _doRequest(request);

    return body["data"][0]["pos"];
  }

  Map<String, dynamic> _doRequest(HttpClientRequest request) async {
    HttpClientResponse response = await request.close();

    if (response.statusCode != HttpStatus.ok) {
      throw Exception("Server returned non 200 status code: ${response.statusCode}");
    }

    return jsonDecode(await response.transform(utf8.decoder).join());
  }

  Future<HttpClientRequest> _requestPairingCode() async {
    return await httpClient
        .postUrl(url.replace(path: tokenPath))
        .then((HttpClientRequest request) {
      request.headers.contentType = ContentType.json;
      request.write("{'id':'$clientId', 'facade': 'pos'}");
      return request;
    });
  }

  /// Converts a public key to a SIN type identifier as per https://en.bitcoin.it/wiki/Identity_protocol_v1.
  String _convertToClientId(ECPublicKey publicKey) {
    var versionedDigest = [prefix, sinType];
    var digest =
        ripemd160digest.process(sha256digest.process(publicKey.Q.getEncoded()));
    versionedDigest.addAll(digest);
    var checksum = sha256digest
        .process(sha256digest.process(Uint8List.fromList(versionedDigest)))
        .getRange(0, 4);
    versionedDigest.addAll(checksum);
    return Base58Codec(alphabet).encode(versionedDigest);
  }
}