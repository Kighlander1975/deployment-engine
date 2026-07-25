# Deployment Engine v0.1 - Overview

## Problemstellung

Deployments duerfen nicht auf unscharfen Dateikopien oder manuell zusammengesuchten ZIP-Paketen beruhen. Gerade Laravel-Projekte enthalten Runtime-Code, Build-Artefakte, Migrationen, Umgebungsvertraege und geschuetzte Serverdateien, die jeweils unterschiedliche Konsequenzen haben.

## Mission

Die Engine soll aus einem bekannten Git-Zustand einen nachvollziehbaren Deployment-Plan ableiten. Sie macht sichtbar, welche Artefakte betroffen sind, welche Schritte erforderlich werden und an welchen Stellen eine bewusste Freigabe notwendig ist.

## Zentrale Begriffe

- `Engine`: Projektuebergreifender Kern fuer Analyse, Klassifikation, Regelbewertung und Planerzeugung.
- `Adapter`: Spaetere projekttyp- oder zielsystembezogene Umsetzungsschicht fuer Ausfuehrung und Verifikation.
- `Projektmanifest`: Projektlokale Konfiguration, die Pfade, Schutzregeln, Klassifikationen und Trigger beschreibt.
- `Baseline`: Der bereits deployte oder explizit gewaehlte Ausgangscommit.
- `Target`: Der zu analysierende Zielcommit, standardmaessig `HEAD`.
- `Deployment-Plan`: Strukturierte, lesbare Beschreibung der erforderlichen Schritte und Risiken.

## Engine, Adapter und Manifest

Die Engine enthaelt keine projektspezifischen Annahmen ausserhalb des Manifests. Das Manifest beschreibt, welche Pfade welche Bedeutung haben und welche Regeln fuer das Projekt gelten. Adapter werden spaeter die Ausfuehrung gegen konkrete Zielsysteme kapseln.

## Abgrenzung zu Kopier- oder ZIP-Skripten

Einfache Kopier- oder ZIP-Skripte behandeln Dateien meist gleichartig. Die Deployment Engine bewertet dagegen Bedeutung und Risiko: Migrationen brauchen Freigabe, Frontendquellen brauchen einen Build, geschuetzte Serverdateien duerfen nicht automatisch ueberschrieben werden und reine Dokumentationsaenderungen benoetigen kein Runtime-Deployment.
