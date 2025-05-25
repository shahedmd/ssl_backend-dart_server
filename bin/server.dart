import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:googleapis_auth/auth_io.dart';

class SSLCommerz {
  final String storeId;
  final String storePassword;

  SSLCommerz(this.storeId, this.storePassword);

  Future<Map<String, dynamic>> initiatePayment(
    double amount,
    String tranId,
    String cusName,
    String email,
    String cusAdd,
    String phoneNumber,
  ) async {
    final url = "https://sandbox.sslcommerz.com/gwprocess/v3/api.php";

    final Map<String, String> paymentData = {
      "store_id": storeId,
      "store_passwd": storePassword,
      "total_amount": amount.toStringAsFixed(2),
      "currency": "BDT",
      "tran_id": tranId,
      "success_url": "http://localhost:8080/payment-success",
      "fail_url": "http://localhost:8080/payment-fail",
      "cancel_url": "http://localhost:8080/payment-cancel",
      "cus_name": cusName,
      "cus_email": email,
      "cus_add1": cusAdd,
      "cus_phone": phoneNumber,
      "cus_city": "Dhaka",
      "cus_postcode": "1207",
      "cus_country": "Bangladesh",
      "shipping_method": "NO",
      "product_name": "Demo Product",
      "product_category": "Demo",
      "product_profile": "general",
    };

    final response = await http.post(
      Uri.parse(url),
      headers: {
        HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
      },
      body: paymentData,
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(
          'Failed to initiate payment. Status: ${response.statusCode}');
    }
  }
}

AutoRefreshingAuthClient? authClient;

Future<AutoRefreshingAuthClient> getAuthClient() async {
  if (authClient != null) return authClient!;
  final accountJson =
      File('D:/sslcommerz_backend/serviceAccount.json').readAsStringSync();
  final credentials = ServiceAccountCredentials.fromJson(accountJson);
  authClient = await clientViaServiceAccount(
      credentials, ['https://www.googleapis.com/auth/datastore']);
  return authClient!;
}

Future<void> saveOrderToFirestore(Map<String, dynamic> orderData) async {
  final client = await getAuthClient();
  final projectId = 'fair-bangla';

  final url = Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/orders');

  // Extract and flatten items from products
  final List itemsRaw = orderData['items'];
  orderData.remove('items');

  final List<Map<String, dynamic>> items = itemsRaw.map((item) {
    final product = item['products'];
    return {
      "id": product['id'],
      "name": product['name'],
      "price": product['price'],
      "imageUrl": product['url'],
      "selectedColor": product['selectedColor'] ?? 'Not Selected',
      "selectedSize": product['selectedSize'] ?? 'Not Selected',
      "quantity": item['quantity'],
    };
  }).toList();

  final firestoreData = {
    "fields": {
      ...orderData.map((key, value) => MapEntry(key, {
            "stringValue": value.toString(),
          })),
      "items": {
        "arrayValue": {
          "values": items.map((item) {
            return {
              "mapValue": {
                "fields": item.map((k, v) => MapEntry(
                      k,
                      v is int
                          ? {"integerValue": v.toString()}
                          : {"stringValue": v.toString()},
                    )),

              }
            };
          }).toList()
        }
      }
    }
  };

  final response = await client.post(
    url,
    headers: {
      HttpHeaders.contentTypeHeader: 'application/json',
    },
    body: jsonEncode(firestoreData),
  );

  if (response.statusCode != 200) {
    throw Exception('Failed to save order: ${response.body}');
  }
}

final pendingOrders = <String, Map<String, dynamic>>{};

void main() async {
  final sslCommerz = SSLCommerz('fairb68111c0477606', 'fairb68111c0477606@ssl');
  final router = Router();

  router.post('/create-payment', (Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);

      if (data['amount'] == null ||
          data['orderId'] == null ||
          data['items'] == null ||
          data['customerData'] == null) {
        return Response(400, body: jsonEncode({'error': 'Invalid data'}));
      }

      final amount = double.tryParse(data['amount'].toString());
      if (amount == null || amount < 10) {
        return Response(400,
            body: jsonEncode({'error': 'Invalid amount. Minimum is 10 BDT'}));
      }

      final tranId = "tran_${DateTime.now().millisecondsSinceEpoch}"; 
      final customer = data['customerData'];

      pendingOrders[tranId] = {
        "orderId": data['orderId'],
        "items": data['items'],
        "total": amount.toString(),
        "status": "Pending",
        "timestamp": DateTime.now().toIso8601String(),
        "customerData": customer,
      };

      final result = await sslCommerz.initiatePayment(
        amount,
        tranId,
        customer['name'],
        customer['email'],
        customer['add'],
        customer['phone'],
      );

      return Response.ok(jsonEncode(result), headers: {
        HttpHeaders.contentTypeHeader: 'application/json',
      });
    } catch (e) {
      return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}));
    }
  });

  router.post('/payment-success', (Request request) async {
    final payload = await request.readAsString();
    final data = Uri.splitQueryString(payload);
    final tranId = data['tran_id'];
    final tempOrder = pendingOrders[tranId];

    if (data['status'] == 'VALID' && tempOrder != null) {
      final customer = tempOrder['customerData'];

      final order = {
        "orderId": tempOrder['orderId'],
        "items": tempOrder['items'],
        "total": tempOrder['total'],
        "transNumber": tranId,
        "phone": customer['phone'],
        "email": customer['email'],
        "name": customer['name'],
        "address": customer['add'],
        "status": "Confirmed",
        "timestamp": DateTime.now().toIso8601String(),
      };

      await saveOrderToFirestore(order);
      pendingOrders.remove(tranId);

      return Response.ok('''<html><head><title>Payment Success</title></head><body>
        <h1>🎉 Payment Successful</h1><p>Your order has been confirmed and saved.</p></body></html>''', headers: {
        HttpHeaders.contentTypeHeader: 'text/html'});
    } else {
      return Response(400, body: '❌ Invalid or missing transaction');
    }
  });

  router.get('/payment-fail', (_) async => Response.ok('❌ পেমেন্ট ব্যর্থ হয়েছে।'));
  router.get('/payment-cancel', (_) async => Response.ok('❌ আপনি পেমেন্ট বাতিল করেছেন।'));

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsHeaders(headers: {
        ACCESS_CONTROL_ALLOW_ORIGIN: '*',
        ACCESS_CONTROL_ALLOW_HEADERS: '*',
        ACCESS_CONTROL_ALLOW_METHODS: 'POST,GET,OPTIONS',
      }))
      .addHandler(router);

  final server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
  print('✅ Server running on http://${server.address.host}:${server.port}');
}
