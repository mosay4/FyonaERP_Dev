extension StringExtensions on String {
  bool get isValidEmail {
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    return emailRegex.hasMatch(this);
  }

  bool get isValidPhone {
    final phoneRegex = RegExp(r'^\+?[\d\s-]{7,15}$');
    return phoneRegex.hasMatch(this);
  }

  bool get isValidPassword {
    if (length < 8) return false;
    if (!contains(RegExp('[A-Z]'))) return false;
    if (!contains(RegExp('[a-z]'))) return false;
    if (!contains(RegExp('[0-9]'))) return false;
    if (!contains(RegExp('[!@#\$%^&*()_+=\\-\\[\\]{};:.,<>/?]'))) return false;
    return true;
  }

  String capitalize() {
    if (isEmpty) return this;
    return '${this[0].toUpperCase()}${substring(1)}';
  }

  String get trimmed => trim();

  String truncate(int maxLength) {
    if (length <= maxLength) return this;
    return '${substring(0, maxLength)}...';
  }

  String toTitleCase() {
    return split(' ').map((word) => word.capitalize()).join(' ');
  }
}
