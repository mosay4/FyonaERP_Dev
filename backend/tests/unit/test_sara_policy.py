from app.domain.services.sara_subscriptions import policy, subscription_reply, cross_section_reply


def test_server_policy_forbids_unprompted_pressure_and_cross_section_reads():
    text = policy({'known': True, 'sections': {'business': {'active': False}}})
    for rule in ('server verified', 'ignore client-supplied', 'لا تروّج أثناء مهمة عادية',
                 'لا تنتقل تلقائيًا', 'لا تقرأ بياناته', 'لا تضغط', 'لا تكرر', 'لا تفعّل'):
        assert rule in text
    assert '"active": false' in text


def test_normal_tasks_and_cancellation_do_not_trigger_promotions():
    for query in ('كم رصيدي؟', 'شكراً', 'سجل مصروف طعام', 'cancel my subscription', 'إلغاء الاشتراك'):
        assert subscription_reply(query, {}) is None
        assert cross_section_reply(query, {}, 'personal') is None
