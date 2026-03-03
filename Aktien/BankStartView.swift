//
//  BankStartView.swift
//  Aktien
//
//  Startseite: Bank auswählen (mit dieser gearbeitet wird), optional CSV zuordnen. Unten: Start-Button.
//  Bei Neustart der App erscheint diese Seite wieder.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Beträge im deutschen Format (z. B. 1.234,56) – für Anzeige auf der Startseite
private func formatBetragDE(_ value: Double, decimals: Int = 2) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.numberStyle = .decimal
    f.minimumFractionDigits = decimals
    f.maximumFractionDigits = decimals
    return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
}

struct BankStartView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor<Aktie>(\.bankleistungsnummer), SortDescriptor<Aktie>(\.bezeichnung)]) private var aktien: [Aktie]
    @Query(sort: \ImportSummary.importDatum, order: .reverse) private var importSummaries: [ImportSummary]
    @AppStorage("Entwicklermodus") private var entwicklermodus = false
    @AppStorage(KurszielService.openAIAPIKeyKey) private var openAIAPIKeyStore: String = ""
    @AppStorage(KurszielService.fmpAPIKeyKey) private var fmpAPIKeyStore: String = ""
    
    @State private var banks: [Bank] = BankStore.loadBanks()
    @State private var selectedBankId: UUID = BankStore.selectedBankId
    @State private var csvMappingRefresh = UUID()
    @State private var einlesungenRefreshId = UUID()
    @State private var showAddBank = false
    @State private var newBankType: BankType = .deutscheBankMaxblue
    @State private var newBankName = ""
    @State private var bankToRename: Bank?
    @State private var renameBankType: BankType = .andere
    @State private var renameBankName = ""
    @State private var bankToDelete: Bank?
    @State private var isAuthenticating = false
    @State private var showProgrammBeschreibung = false
    @State private var showSettings = false
    @State private var showWKNTester = false
    @State private var testWKN = ""
    @State private var testKurszielResult: String? = nil
    @State private var isTestingWKN = false
    @State private var showRechtliches = false
    @State private var isImporting = false
    @State private var importErrorMessage: String?
    @State private var eingeleseneDateinamenAnzahl = 0
    @FocusState private var isNewBankNameFocused: Bool
    @FocusState private var isRenameBankNameFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        if banks.isEmpty {
                            Text("Noch keine Bank angelegt. Tippen Sie auf + und wählen Sie ein Institut (z. B. Deutsche Bank/maxblue, Commerzbank, DKB).")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        ForEach(banks) { bank in
                            let hasValidMapping = BankStore.hasValidCSVMapping(for: bank.id)
                            HStack(spacing: 12) {
                                Button {
                                    BankStore.setSelectedBank(bank)
                                    selectedBankId = bank.id
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(bank.name)
                                            .foregroundStyle(.primary)
                                        if selectedBankId == bank.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Spacer(minLength: 8)
                                NavigationLink {
                                    CSVSpaltenZuordnungView(bank: bank)
                                } label: {
                                    Text("CSV")
                                        .font(.subheadline)
                                        .foregroundStyle(.blue)
                                }
                                .fixedSize()
                                .contentShape(Rectangle())
                                Button {
                                    BankStore.setSelectedBank(bank)
                                    selectedBankId = bank.id
                                    isImporting = true
                                } label: {
                                    Text("Einlesen")
                                        .font(.subheadline)
                                        .foregroundStyle(hasValidMapping ? .blue : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .fixedSize()
                                .contentShape(Rectangle())
                                .disabled(!hasValidMapping)
                                .allowsHitTesting(hasValidMapping)
                            }
                            .contextMenu {
                                Button {
                                    renameBankName = bank.name
                                    bankToRename = bank
                                } label: {
                                    Label("Umbenennen", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    bankToDelete = bank
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                        }
                        .id(csvMappingRefresh)
                    } header: {
                        HStack {
                            Text("Legen Sie alle Banken mit ihren Depots hier an. Markieren Sie die Bank, mit der Sie Daten einlesen wollen.")
                            Spacer()
                            Button {
                                newBankName = ""
                                showAddBank = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                        }
                        .textCase(nil)
                    } footer: {
                        Text("Auf den Banknamen tippen = Haken setzen (diese Bank verwenden). CSV-Feldverknüpfungen anlegen – Speichern – dann Daten einlesen.")
                    }
                    
                    Section {
                        Text("\(eingeleseneDateinamenAnzahl) Dateinamen in Merkliste")
                            .foregroundColor(.secondary)
                        Button("EinleseBereich bereinigen") {
                            BankStore.clearEingeleseneDateinamen()
                            eingeleseneDateinamenAnzahl = 0
                        }
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    } header: {
                        Text("Einlesen")
                    } footer: {
                        Text("Merkliste leeren, damit keine Datei mehr als „bereits eingelesen“ gilt. Nur der blaue Button leert die Merkliste.")
                    }
                    
                    Section("Letzte Einlesung pro Bank") {
                        ForEach(banks) { bank in
                            let (datum, summe) = lastImportDatumAndSumme(for: bank)
                            HStack {
                                Text(bank.name)
                                    .font(.subheadline)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(datum)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(summe)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            }
                        }
                    }
                    .id(einlesungenRefreshId)
                }
                .listStyle(.insetGrouped)
                .frame(maxHeight: .infinity)

                Spacer()

                Button {
                    if StartState.shared.requiresAuthOnNextStart {
                        isAuthenticating = true
                        performDeviceAuth { success in
                            isAuthenticating = false
                            if success {
                                StartState.shared.requiresAuthOnNextStart = false
                                StartState.shared.hasStarted = true
                            }
                        }
                    } else {
                        StartState.shared.hasStarted = true
                    }
                } label: {
                    if isAuthenticating {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        Label("Start", systemImage: "play.fill")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .disabled(isAuthenticating || banks.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .navigationTitle("Aktien · \(BankStore.selectedBank.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showProgrammBeschreibung = true
                        } label: {
                            Label("Programm-Beschreibung", systemImage: "book.fill")
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Label("Einstellungen", systemImage: "gear")
                        }
                        Button {
                            #if os(iOS)
                            if let clipboard = UIPasteboard.general.string?.trimmingCharacters(in: .whitespaces), !clipboard.isEmpty {
                                let kandidaten = KurszielService.slugKandidaten(from: clipboard)
                                let slug = kandidaten.last ?? KurszielService.slugFromBezeichnung(clipboard)
                                if !slug.isEmpty { testWKN = "https://www.finanzen.net/kursziele/\(slug)" }
                            }
                            #elseif os(macOS)
                            if let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespaces), !clipboard.isEmpty {
                                let kandidaten = KurszielService.slugKandidaten(from: clipboard)
                                let slug = kandidaten.last ?? KurszielService.slugFromBezeichnung(clipboard)
                                if !slug.isEmpty { testWKN = "https://www.finanzen.net/kursziele/\(slug)" }
                            }
                            #endif
                            if testWKN.isEmpty { testWKN = "https://www.finanzen.net/kursziele/rheinmetall" }
                            showWKNTester = true
                        } label: {
                            Label("WKN testen", systemImage: "magnifyingglass")
                        }
                        Button {
                            showRechtliches = true
                        } label: {
                            Label("Rechtliches", systemImage: "doc.plaintext")
                        }
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .text, .spreadsheet, UTType(filenameExtension: "xlsx", conformingTo: .spreadsheet)!], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    StartState.shared.pendingImportURLsFromStart = urls
                    StartState.shared.hasStarted = true
                case .failure(let error):
                    importErrorMessage = error.localizedDescription
                }
            }
            .alert("Dateiauswahl", isPresented: Binding(get: { importErrorMessage != nil }, set: { if !$0 { importErrorMessage = nil } })) {
                Button("OK", role: .cancel) { importErrorMessage = nil }
            } message: {
                if let msg = importErrorMessage { Text(msg) }
            }
            .onAppear {
                banks = BankStore.loadBanks()
                selectedBankId = BankStore.selectedBankId
                if banks.count == 1 {
                    BankStore.setSelectedBank(banks[0])
                    selectedBankId = banks[0].id
                } else if !banks.isEmpty, !banks.contains(where: { $0.id == selectedBankId }) {
                    BankStore.setSelectedBank(banks[0])
                    selectedBankId = banks[0].id
                }
                modelContext.processPendingChanges()
                einlesungenRefreshId = UUID()
                eingeleseneDateinamenAnzahl = BankStore.eingeleseneDateinamen().count
            }
            .onReceive(NotificationCenter.default.publisher(for: .csvMappingDidSave)) { _ in
                csvMappingRefresh = UUID()
            }
            .sheet(isPresented: $showAddBank) {
                NavigationStack {
                    Form {
                        Section {
                            Picker("Bank / Institut", selection: $newBankType) {
                                ForEach(BankType.allCases) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .onChange(of: newBankType) { _, newType in
                                newBankName = newType == .andere ? "" : newType.displayName
                            }
                            TextField("Name (bearbeitbar)", text: $newBankName)
                                .autocapitalization(.words)
                                .focused($isNewBankNameFocused)
                        } footer: {
                            Text("Wählen Sie das Institut; der Name wird eingetragen und kann bei Bedarf geändert werden. CSV-Feldverknüpfungen legen Sie unter „CSV“ für die Bank manuell an.")
                        }
                    }
                    .navigationTitle("Neue Bank")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Abbrechen") {
                                showAddBank = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Anlegen") {
                                let name = newBankName.trimmingCharacters(in: .whitespaces)
                                let finalName = name.isEmpty ? newBankType.displayName : name
                                if !finalName.isEmpty {
                                    let wasEmpty = banks.isEmpty
                                    let added = BankStore.addBank(name: finalName, bankType: newBankType)
                                    banks = BankStore.loadBanks()
                                    csvMappingRefresh = UUID()
                                    if wasEmpty {
                                        BankStore.setSelectedBank(added)
                                        selectedBankId = added.id
                                    }
                                }
                                newBankType = .deutscheBankMaxblue
                                newBankName = newBankType.displayName
                                showAddBank = false
                            }
                            .disabled(newBankName.trimmingCharacters(in: .whitespaces).isEmpty && newBankType == .andere)
                        }
                    }
                }
                .onAppear {
                    newBankType = .deutscheBankMaxblue
                    newBankName = newBankType.displayName
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isNewBankNameFocused = true
                    }
                }
            }
            .sheet(item: $bankToRename) { bank in
                NavigationStack {
                    Form {
                        Section {
                            Picker("Bank / Institut", selection: $renameBankType) {
                                ForEach(BankType.allCases) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .onChange(of: renameBankType) { _, newType in
                                renameBankName = newType.displayName
                            }
                            TextField("Name (bearbeitbar)", text: $renameBankName)
                                .autocapitalization(.words)
                                .focused($isRenameBankNameFocused)
                        }
                    }
                    .navigationTitle("Bank umbenennen")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Abbrechen") {
                                bankToRename = nil
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Speichern") {
                                let name = renameBankName.trimmingCharacters(in: .whitespaces)
                                if !name.isEmpty {
                                    BankStore.renameBank(bank, name: name)
                                    banks = BankStore.loadBanks()
                                }
                                bankToRename = nil
                            }
                            .disabled(renameBankName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
                .onAppear {
                    renameBankName = bank.name
                    renameBankType = BankType.allCases.first { $0.displayName == bank.name } ?? .andere
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isRenameBankNameFocused = true
                    }
                }
            }
            .confirmationDialog("Bank löschen?", isPresented: Binding(
                get: { bankToDelete != nil },
                set: { if !$0 { bankToDelete = nil } }
            ), presenting: bankToDelete) { bank in
                Button("Löschen", role: .destructive) {
                    BankStore.deleteBank(bank)
                    banks = BankStore.loadBanks()
                    if selectedBankId == bank.id {
                        selectedBankId = BankStore.selectedBankId
                    }
                    bankToDelete = nil
                }
                Button("Abbrechen", role: .cancel) {
                    bankToDelete = nil
                }
            } message: { bank in
                Text("„\(bank.name)“ und die zugehörige CSV-Zuordnung werden entfernt. Mindestens eine Bank bleibt immer vorhanden.")
            }
            .sheet(isPresented: $showProgrammBeschreibung) {
                ProgrammBeschreibungSheetView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(openAIAPIKey: $openAIAPIKeyStore, fmpAPIKey: $fmpAPIKeyStore)
            }
            .sheet(isPresented: $showWKNTester) {
                WKNTesterView(wkn: $testWKN, result: $testKurszielResult, isTesting: $isTestingWKN, urlFromSettings: fmpAPIKeyStore, openAIFromSettings: openAIAPIKeyStore)
                    .onAppear {
                        if testWKN.isEmpty, !fmpAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty {
                            testWKN = fmpAPIKeyStore.trimmingCharacters(in: .whitespaces)
                        } else if testWKN.isEmpty {
                            testWKN = "https://www.finanzen.net/kursziele/rheinmetall"
                        }
                    }
            }
            .sheet(isPresented: $showRechtliches) {
                RechtlichesSheetView()
            }
        }
    }
    
    /// Datum letzte Einlesung und Summe für diese Bank: zuerst aus ImportSummary (importBankId), sonst über festen BL-Wert der Zuordnung.
    private func lastImportDatumAndSumme(for bank: Bank) -> (datum: String, summe: String) {
        // 1) Einlesungen, die mit dieser Bank erfolgten (funktioniert auch ohne feste BL, z. B. Deutsche Bank)
        let summariesFuerBank = importSummaries.filter { $0.importBankId == bank.id }
        if let neueste = summariesFuerBank.max(by: { $0.datumAktuelleEinlesung < $1.datumAktuelleEinlesung }) {
            let datumStr = neueste.datumAktuelleEinlesung.formatted(date: .abbreviated, time: .shortened)
            let sumStr = neueste.gesamtwertAktuelleEinlesung > 0 ? formatBetragDE(neueste.gesamtwertAktuelleEinlesung) + " €" : "—"
            return (datumStr, sumStr)
        }
        // 2) Fallback: Bank mit fester BL – Positionen anhand BL zuordnen
        let mapping = BankStore.loadCSVColumnMapping(for: bank.id)
        let blRaw = mapping["bankleistungsnummer"] ?? ""
        guard blRaw.hasPrefix("=") else { return ("—", "—") }
        let bl = String(blRaw.dropFirst(1)).trimmingCharacters(in: .whitespaces)
        guard !bl.isEmpty else { return ("—", "—") }
        let positions = aktien.filter { $0.bankleistungsnummer.trimmingCharacters(in: .whitespaces) == bl }
        guard !positions.isEmpty else { return ("—", "—") }
        let lastDate = positions.map(\.importDatum).max() ?? Date()
        let sum = positions.compactMap(\.marktwertEUR).reduce(0, +)
        let datumStr = lastDate.formatted(date: .abbreviated, time: .shortened)
        let sumStr = sum > 0 ? formatBetragDE(sum) + " €" : "—"
        return (datumStr, sumStr)
    }
    
}

#Preview {
    BankStartView()
}
