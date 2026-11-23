import sys
sys.path.insert(0, '.')
from alembic.config import Config
from alembic.script import ScriptDirectory

cfg = Config()
cfg.set_main_option('script_location', 'migrations')
cfg.set_main_option('prepend_sys_path', '.')

scripts = ScriptDirectory.from_config(cfg)
heads = scripts.get_heads()
current = scripts.get_current_head()
branches = scripts.get_bases()
print('Bases (roots):', branches)

# Check 022
rev_022 = scripts.get_revision('022')
print('022 down_revision:', rev_022.down_revision)
print('022 branch_labels:', rev_022.branch_labels)

# Check 021
rev_021 = scripts.get_revision('021')
print('021 down_revision:', rev_021.down_revision)

# Check 020
rev_020 = scripts.get_revision('020')
print('020 down_revision:', rev_020.down_revision)

# All revisions
all_revs = scripts.get_revisions()
print(f'Total revisions: {len(all_revs)}')
for rev in sorted(all_revs, key=lambda r: r.revision):
    print(f'  {rev.revision}: down={rev.down_revision}')
