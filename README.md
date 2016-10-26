# Multi IDP & SP import tool for ADFS
Haka, Virtu, eduGAIN and Kalmarin Unionin are using metadata format where one metadata contains many IDPs and SPs.

ADFS supports only one IDP and SP on each metadata so this script splits each IDP and SP to own file and import them to ADFS one by one.