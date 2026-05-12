local plentest_path = os.getenv('PLENTEST') or ''
vim.o.rtp = plentest_path .. ',.,./runtime,' .. vim.o.rtp
require('plentest').test_directory('tests/init_spec.lua')
