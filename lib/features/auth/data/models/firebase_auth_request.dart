class FirebaseAuthRequest {
  final String idToken;

  const FirebaseAuthRequest({required this.idToken});

  Map<String, dynamic> toJson() => {
        'id_token': idToken,
      };
}
