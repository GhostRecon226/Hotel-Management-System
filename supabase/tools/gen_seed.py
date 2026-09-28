import sys
sys.path.insert(0,__import__('os').path.dirname(__import__('os').path.abspath(__file__)))
import data_perm as d
def q(x): return "'" + str(x).replace("'", "''") + "'"
out=[]
out.append("-- HMS 0010: reference data. Generated from HMS_R1_Foundation_Spec.xlsx v0.4 (Roles, Permissions).\n-- Re-run scratchpad/gen_seed.py if the workbook changes, then add a NEW migration for the difference. Never edit an applied one.\n")
out.append("""
insert into public.currencies (code, name, decimals) values
 ('NGN','Nigerian naira',2),('USD','US dollar',2),('EUR','Euro',2),('GBP','Pound sterling',2),
 ('GHS','Ghanaian cedi',2),('KES','Kenyan shilling',2),('ZAR','South African rand',2),
 ('XOF','West African CFA franc',0),('UGX','Ugandan shilling',0),('TZS','Tanzanian shilling',2),('RWF','Rwandan franc',0)
on conflict (code) do nothing;

-- Plans are configuration (A16). Prices are left empty until Peter sets them.
insert into public.plans (code, name, max_rooms, max_properties, max_users, trial_days) values
 ('starter','Starter',20,1,10,30),
 ('standard','Standard',60,1,25,30),
 ('pro','Pro',150,3,60,30),
 ('enterprise','Enterprise',null,null,null,30)
on conflict (code) do nothing;
""")
tax_ng = '''[
 {"code":"SC","name":"Service charge","rate":10,"calc_base":"net","seq":1,"applies_to":["room","fnb","other"],"verified":false},
 {"code":"VAT","name":"VAT","rate":7.5,"calc_base":"net_plus_prior","seq":2,"applies_to":["room","fnb","other"],"verified":false},
 {"code":"STATE_LEVY","name":"State hotel and consumption levy (set your state rate)","rate":0,"calc_base":"net","seq":3,"applies_to":["room","fnb"],"verified":false}
]'''
pm = '''[
 {"code":"CASH","name":"Cash","kind":"cash"},
 {"code":"POS","name":"Card (POS terminal)","kind":"card_terminal"},
 {"code":"TRANSFER","name":"Bank transfer","kind":"bank_transfer"},
 {"code":"OTHER","name":"Other","kind":"other"}
]'''
cc = '''[
 {"code":"ROOM","name":"Room charge","revenue_group":"room","taxable":true,"is_system":true},
 {"code":"FEE_CXL","name":"Cancellation fee","revenue_group":"fee","taxable":false,"is_system":true},
 {"code":"FEE_NOSHOW","name":"No-show fee","revenue_group":"fee","taxable":false,"is_system":true},
 {"code":"LAUNDRY","name":"Laundry","revenue_group":"other","taxable":true},
 {"code":"MINIBAR","name":"Minibar","revenue_group":"fnb","taxable":true},
 {"code":"RESTAURANT","name":"Restaurant","revenue_group":"fnb","taxable":true},
 {"code":"EARLY_CI","name":"Early check-in","revenue_group":"room","taxable":true},
 {"code":"LATE_CO","name":"Late check-out","revenue_group":"room","taxable":true},
 {"code":"MISC","name":"Miscellaneous","revenue_group":"other","taxable":true}
]'''
def tpl(cc_, name, cur, tz, tax, verified, notes):
    return f"({q(cc_)},{q(name)},{q(cur)},{q(tz)},{q(tax)}::jsonb,{q(pm)}::jsonb,{q(cc)}::jsonb,{verified},{q(notes)})"
rows=[
 tpl('NG','Nigeria','NGN','Africa/Lagos',tax_ng,'false','VAT 7.5%, service charge 10% and state levy lines are starting values. A local accountant must confirm them before a hotel goes live (assumption A11).'),
 tpl('GH','Ghana','GHS','Africa/Accra','[]','false','No tax lines seeded. Add the levies that apply.'),
 tpl('KE','Kenya','KES','Africa/Nairobi','[]','false','No tax lines seeded. Add the levies that apply.'),
 tpl('ZA','South Africa','ZAR','Africa/Johannesburg','[]','false','No tax lines seeded. Add the levies that apply.'),
 tpl('ZZ','Generic (any other country)','USD','UTC','[]','false','Fallback template. Set currency, timezone and taxes for the property.'),
]
out.append("insert into public.country_templates (country_code, name, currency, timezone, tax_lines, payment_methods, charge_codes, verified, notes) values\n "+",\n ".join(rows)+"\non conflict (country_code) do nothing;\n")
# permissions
pv=[]
for key,mod,rel,desc,s in d.PERMS:
    pv.append(f"({q(key)},{q(mod)},{q(rel)},{q(desc)},{'true' if s=='S' else 'false'})")
out.append("insert into public.permissions (key, module, release, description, sensitive) values\n "+",\n ".join(pv)+"\non conflict (key) do nothing;\n")
rv=[]
for code,name,maps,rel,scope,note in d.ROLES:
    rv.append(f"({q(code)},{q(name)},{q(note)},{q(rel)})")
out.append("insert into public.roles (tenant_id, code, name, description, first_release, is_system)\nselect null, v.code, v.name, v.description, v.rel, true from (values\n "+",\n ".join(rv)+"\n) as v(code, name, description, rel)\nwhere not exists (select 1 from public.roles r where r.tenant_id is null and r.code = v.code);\n")
g=d.grid()
gv=[]
for (role,key),c in g.items():
    if c: gv.append(f"({q(role)},{q(key)},{q(c)})")
out.append("insert into public.role_permissions (role_id, permission_key, grant_level)\nselect r.id, v.k, v.lvl from (values\n "+",\n ".join(gv)+"\n) as v(role, k, lvl)\njoin public.roles r on r.tenant_id is null and r.code = v.role\non conflict do nothing;\n")
import os
open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','migrations','20260928001000_seed_reference_data.sql'),'w').write("\n".join(out))
print(len(gv),'grants')
