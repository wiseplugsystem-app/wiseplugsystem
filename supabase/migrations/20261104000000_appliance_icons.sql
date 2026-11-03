-- Appliance icons: each appliance type keeps the key of its icon, so every
-- appliance of that type shows the same icon (lib/models/appliance_icons.dart
-- maps the key to the icon). The app sends the key when a new type is
-- registered ("What are you adding?"). A missing or unknown key shows the
-- general "Other" icon. Nothing is removed.
alter table public.appliance_types
  add column icon_key text check (icon_key is null or icon_key ~ '^[a-z_]{1,32}$');

-- Types made before this: the same words the app matches on
-- (appliance_icons.dart, applianceKinds, in the same order).
update public.appliance_types set icon_key = case
    when lower(name) like '%fan%'                                            then 'fan'
    when lower(name) like '%rice%'                                           then 'rice_cooker'
    when lower(name) like '%iron%' or lower(name) like '%straightener%'      then 'flat_iron'
    when lower(name) like '%fryer%'                                          then 'air_fryer'
    when lower(name) like '%microwave%'                                      then 'microwave'
    when lower(name) like '%kettle%'                                         then 'kettle'
    when lower(name) like '%tv%' or lower(name) like '%television%'          then 'tv'
    when lower(name) like '%fridge%' or lower(name) like '%refrigerator%'    then 'refrigerator'
    when lower(name) like '%laptop%' or lower(name) like '%computer%'        then 'laptop_charger'
    when lower(name) like '%phone%' or lower(name) like '%charger%'          then 'phone_charger'
    when lower(name) like '%lamp%' or lower(name) like '%bulb%' or lower(name) like '%light%' then 'lamp'
    when lower(name) like '%dispenser%'                                      then 'water_dispenser'
    when lower(name) like '%hair%' or lower(name) like '%dryer%'             then 'hair_dryer'
    when lower(name) like '%blender%'                                        then 'blender'
    when lower(name) like '%induction%' or lower(name) like '%stove%'        then 'induction_cooker'
    when lower(name) like '%washing%' or lower(name) like '%washer%' or lower(name) like '%laundry%' then 'washing_machine'
    when lower(name) like '%aircon%' or lower(name) like '%air con%' or lower(name) like '%air-con%'
      or lower(name) like '%conditioner%'                                    then 'aircon'
    else 'other'
  end
where icon_key is null;
