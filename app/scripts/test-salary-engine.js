// Unit tests of the salary calculator:  node scripts/test-salary-engine.js [path-to-old-wages.js]
// 1. the STARTING formulas give the same numbers as the old fixed Wage Register calculation (when the old wages.js is given)
// 2. hand-calculated rows   3. wrong / dangerous formulas are refused   4. a changed formula + an added row
const ts = require('typescript'); const fs = require('fs'); const os = require('os'); const path = require('path');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'eng-'));
fs.writeFileSync(path.join(dir, 'e.js'), ts.transpileModule(fs.readFileSync(path.join(__dirname, '../src/lib/salaryEngine.ts'), 'utf8'), { compilerOptions: { module: 'CommonJS', target: 'ES2020' } }).outputText);
const E = require(path.join(dir, 'e.js'));
let fail = 0; const eq = (name, got, want) => { const ok = JSON.stringify(got) === JSON.stringify(want); if (!ok) fail++; console.log(ok ? 'PASS' : 'FAIL', name, ok ? '' : `got ${JSON.stringify(got)} want ${JSON.stringify(want)}`); };
const pay = (sal, paid, days) => ({ user_id: 'u', username: 'e', full_name: 'A', department: '', monthly_salary: sal, days_in_month: days, present: paid, absent: 0, leave_days: 0, paid_leave: 0, unpaid_leave: 0, not_joined: 0, unpaid_days: days - paid, payable_days: paid, overtime_hours: 0, overtime_pay: 0, deduction: 0, net_salary: 0 });
const w = (sal, paid, days, m = 11, ex = {}, items = E.STARTING_ITEMS) => E.computeSalary(pay(sal, paid, days), m, items, ex);

// 1. same numbers as the old fixed calculation
if (process.argv[2]) {
  const old = require(path.resolve(process.argv[2]));
  const keys = ['gross', 'daysPresent', 'daysUnpaid', 'daysInMonth', 'basic', 'hra', 'other', 'overtime', 'totalGross', 'pfEmployee', 'pt', 'esicEmployee', 'pfEmployer', 'esicEmployer', 'advance', 'totalDeduct', 'net', 'pfMember', 'epsEligible', 'pfWages', 'epsWages', 'employerEps', 'employerEpf', 'employerCost', 'name', 'gender', 'department'];
  let bad = 0; const N = 30000;
  for (let i = 0; i < N; i++) {
    const sal = [0, 5000, 7500, 9000, 10000, 15000, 20000, 21000, 21001, 25000, 38000, 60000, 130000, 12345 + Math.floor(Math.random() * 90000)][Math.floor(Math.random() * 14)];
    const md = [28, 29, 30, 31][Math.floor(Math.random() * 4)]; const paid = Math.floor(Math.random() * (md + 1));
    const m = 1 + Math.floor(Math.random() * 12); const ex = { gender: ['Male', 'Female', '', 'Other'][Math.floor(Math.random() * 4)], advance: Math.random() < 0.1 ? 500 : 0 };
    const p = pay(sal, paid, md); const a = old.wageRow(p, m, ex); const b = E.computeSalary(p, m, E.STARTING_ITEMS, ex);
    for (const k of keys) if (a[k] !== b[k]) { bad++; if (bad < 6) console.log('DIFF', k, a[k], b[k], JSON.stringify(p), m, ex); break; }
  }
  eq(`starting formulas vs old Wage Register (${N} random cases)`, bad, 0);
}
// 2. hand-calculated rows
let r = w(130000, 15, 30); eq('130000/15/30 basic', r.basic, 32500); eq('gross', r.totalGross, 65000); eq('PF', r.pfEmployee, 3000); eq('PT', r.pt, 200); eq('ESIC', r.esicEmployee, 0); eq('net', r.net, 61800);
r = w(38000, 29, 30); eq('38000/29/30 basic', r.basic, 18367); eq('gross', r.totalGross, 36734); eq('PF', r.pfEmployee, 2204);
r = w(15000, 30, 30); eq('15000 ESIC employee', r.esicEmployee, 113); eq('ESIC employer', r.esicEmployer, 488); eq('PT', r.pt, 200);
eq('February PT', w(15000, 30, 30, 2).pt, 300); eq('men 9000 PT', w(9000, 30, 30).pt, 175); eq('men 7000 PT', w(7000, 30, 30).pt, 0); eq('women 20000 PT', w(20000, 30, 30, 11, { gender: 'Female' }).pt, 0);
// 3. refused formulas (each checked as a PF row)
const rowWith = (text) => E.STARTING_ITEMS.map((x) => (x.code === 'PF' ? { ...x, formula: text } : { ...x }));
const idx = 3;
for (const bad of ['alert(1)', 'process', 'ROUND(SALARY * 2', 'SALARY * 2)', 'FOO * 2', 'eval("1")', 'constructor.constructor("x")()', '1; 2', '', 'SALARY +', 'AND(1, 1)', 'ROUNDDOWN(SALARY)', 'NET * 2'])
  eq(`refused: ${bad}`, E.checkRow(rowWith(bad), idx) !== null, true);
eq('BASIC cannot use GROSS (later row)', E.checkRow(E.STARTING_ITEMS.map((x) => (x.code === 'BASIC' ? { ...x, formula: 'GROSS * 50%' } : x)), 0) !== null, true);
eq('a valid PF formula', E.checkRow(rowWith('ROUND(BASIC * 12%)'), idx), null);
let zero = false; try { E.evaluate(E.parseFormula('SALARY / 0'), { SALARY: 1 }); } catch { zero = true; } eq('division by zero is an error', zero, true);
// 4. changed ESIC limit + added Earning (counts in Gross and Net)
const conv = { code: 'CONV', name: 'Conveyance allowance', type: 'earning', formula: 'ROUND(1600 * PAID_DAYS / MONTH_DAYS)' };
const items2 = [...E.STARTING_ITEMS.map((x) => (x.code === 'ESIC' ? { ...x, formula: x.formula.replace('21000', '25000') } : x)), conv];
eq('all rows of the new set are correct', E.checkAll(items2).every((x) => x === null), true);
const a = w(23000, 29, 30, 12), b = w(23000, 29, 30, 12, {}, items2);
eq('before: no ESIC', a.esicEmployee, 0); eq('after: ESIC applies', b.esicEmployee > 0, true); eq('added earning amount', b.extras.CONV, 1547);
eq('net follows gross', b.net, b.totalGross - b.totalDeduct); eq('gross includes the added earning', b.totalGross, b.basic + b.hra + b.other + 1547);
console.log(fail ? `\n${fail} FAILED` : '\nAll tests passed'); process.exit(fail ? 1 : 0);
