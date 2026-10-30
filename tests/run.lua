-- Run with:  lua5.4 tests/run.lua            (all suites)
--            lua5.4 tests/run.lua players    (suites whose file name contains "players")

local root = (arg[0]:match('^(.*)/[^/]*$')) or '.'
package.path = root .. '/?.lua;' .. package.path

local H = require('harness')
local filter = arg[1]

local suites = {}
local p = io.popen(('ls -1 %s/*_test.lua'):format(root))
for line in p:lines() do
    if not filter or line:find(filter, 1, true) then suites[#suites + 1] = line end
end
p:close()
table.sort(suites)

for _, file in ipairs(suites) do
    io.write(('%-40s '):format(file:match('([^/]+)$')))
    local chunk = assert(loadfile(file))
    chunk(H, root .. '/..')
    io.write('\n')
end

local T = H.T
print(('\n%d assertions passed, %d failed'):format(T.passed, T.failed))
for _, failure in ipairs(T.failures) do print('  FAIL ' .. failure) end
os.exit(T.failed == 0 and 0 or 1)
