class AppPagination {
  final int page;
  final int pageSize;
  final int total;
  final int totalPages;

  const AppPagination({
    this.page = 1,
    this.pageSize = 20,
    this.total = 0,
    this.totalPages = 0,
  });

  bool get hasMore => page < totalPages;
  bool get isEmpty => total == 0;

  factory AppPagination.fromJson(Map<String, dynamic> json) {
    return AppPagination(
      page: json['page'] as int? ?? 1,
      pageSize: json['page_size'] as int? ?? 20,
      total: json['total'] as int? ?? 0,
      totalPages: json['total_pages'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'page': page,
        'page_size': pageSize,
        'total': total,
        'total_pages': totalPages,
      };
}

class PaginatedResult<T> {
  final List<T> items;
  final AppPagination pagination;

  const PaginatedResult({required this.items, required this.pagination});

  bool get hasMore => pagination.hasMore;
  bool get isEmpty => items.isEmpty;
}
