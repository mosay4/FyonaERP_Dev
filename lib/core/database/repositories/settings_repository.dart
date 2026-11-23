import '../database_helper.dart';

class SettingsRepository {
  Future<int> insertNotification(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('notifications', data);
  }

  Future<List<Map<String, dynamic>>> getNotifications(int orgId) async {
    return await DatabaseHelper.query('notifications', where: 'organization_id = ?', whereArgs: [orgId], orderBy: 'created_at DESC');
  }

  Future<List<Map<String, dynamic>>> getUserNotifications(int userId) async {
    return await DatabaseHelper.query('notifications', where: 'user_id = ?', whereArgs: [userId], orderBy: 'created_at DESC');
  }

  Future<int> markNotificationRead(int id) async {
    return await DatabaseHelper.update('notifications', {'is_read': 1}, 'id = ?', [id]);
  }

  Future<int> markAllNotificationsRead(int userId) async {
    return await DatabaseHelper.update('notifications', {'is_read': 1}, 'user_id = ?', [userId]);
  }

  Future<int> getUnreadCount(int userId) async {
    final result = await DatabaseHelper.rawQuery('SELECT COUNT(*) as count FROM notifications WHERE user_id = ? AND is_read = 0', [userId]);
    return result.first['count'] as int;
  }

  Future<int> deleteNotification(int id) async {
    return await DatabaseHelper.delete('notifications', 'id = ?', [id]);
  }
}
