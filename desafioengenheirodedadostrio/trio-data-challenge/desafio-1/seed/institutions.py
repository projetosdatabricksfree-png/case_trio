"""Universo de instituições — Single Source of Truth (SSOT).

Esta lista alimenta a tabela `institutions`, dá coerência ao seed de `accounts` e
`transactions` e será reusada pelo dictionary do ClickHouse na Sprint 04
(institution_code -> name). Manter UMA fonte evita divergência cross-banco.

Tupla: (institution_code [ISPB], name, short_name, type, weight)
O `weight` modela participação de mercado (poucos grandes dominam o volume).
Códigos ISPB são reais; nomes aproximados — dados sintéticos para o desafio.
"""
from __future__ import annotations

# fmt: off
INSTITUTIONS: list[tuple[str, str, str, str, int]] = [
    ("00000000", "Banco do Brasil S.A.",              "BB",          "bank",                12),
    ("60746948", "Banco Bradesco S.A.",               "Bradesco",    "bank",                11),
    ("60701190", "Itau Unibanco S.A.",                "Itau",        "bank",                11),
    ("90400888", "Banco Santander (Brasil) S.A.",     "Santander",   "bank",                 9),
    ("00360305", "Caixa Economica Federal",           "Caixa",       "bank",                 9),
    ("18236120", "Nu Pagamentos S.A.",                "Nubank",      "payment_institution", 10),
    ("09526594", "PagSeguro Internet S.A.",           "PagBank",     "payment_institution",  5),
    ("10573521", "Mercado Pago IP Ltda.",             "MercadoPago", "payment_institution",  5),
    ("32402502", "Stone Instituicao de Pagamento",    "Stone",       "payment_institution",  3),
    ("13203354", "Banco Inter S.A.",                  "Inter",       "bank",                 4),
    ("00416968", "Banco Inter (legado)",              "InterLeg",    "bank",                 1),
    ("17184037", "Banco Mercantil do Brasil S.A.",    "Mercantil",   "bank",                 1),
    ("90731688", "Banco BTG Pactual S.A.",            "BTG",         "bank",                 2),
    ("58160789", "Banco Safra S.A.",                  "Safra",       "bank",                 2),
    ("28127603", "Banco C6 S.A.",                     "C6",          "bank",                 3),
    ("31872495", "Banco C6 Consignado",               "C6Cons",      "bank",                 1),
    ("36947229", "Banco Original S.A.",               "Original",    "bank",                 2),
    ("07237373", "Banco Modal S.A.",                  "Modal",       "bank",                 1),
    ("92874270", "Banco Daycoval S.A.",               "Daycoval",    "bank",                 1),
    ("04902979", "Banco BV (Votorantim) S.A.",        "BV",          "bank",                 2),
    ("80271455", "Banco Neon S.A.",                   "Neon",        "payment_institution",  2),
    ("13370835", "Pic Pay Servicos S.A.",             "PicPay",      "payment_institution",  4),
    ("19540550", "Asaas IP S.A.",                     "Asaas",       "payment_institution",  1),
    ("13935893", "Cielo S.A.",                        "Cielo",       "payment_institution",  2),
    ("01027058", "GetNet Adquirencia S.A.",           "GetNet",      "payment_institution",  2),
    ("00795423", "Banco Sicoob S.A.",                 "Sicoob",      "credit_union",         3),
    ("01181521", "Banco Sicredi S.A.",                "Sicredi",     "credit_union",         3),
    ("04632856", "Cooperativa Ailos",                 "Ailos",       "credit_union",         1),
    ("31597552", "Banco Cora SCD S.A.",               "Cora",        "fintech",              2),
    ("34335592", "Iti (Itau) IP",                     "Iti",         "fintech",              2),
]
# fmt: on


def codes() -> list[str]:
    return [row[0] for row in INSTITUTIONS]
