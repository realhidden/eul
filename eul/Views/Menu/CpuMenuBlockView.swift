//
//  CpuMenuBlockView.swift
//  eul
//
//  Created by Gao Sun on 2020/9/20.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SharedLibrary
import SwiftUI

struct CpuMenuBlockView: View {
    @EnvironmentObject var preferenceStore: PreferenceStore
    @EnvironmentObject var cpuStore: CpuStore
    @EnvironmentObject var cpuTopStore: TopStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                Text("component.cpu".localized())
                    .menuSection()
                Spacer()
                if preferenceStore.cpuMenuDisplay == .usagePercentage {
                    Text(cpuStore.usageString)
                        .displayText()
                }
                LineChart(points: cpuStore.usageHistory, frame: CGSize(width: 35, height: 20))
            }
            cpuStore.usageCPU.map { usageCPU in
                Group {
                    SeparatorView()
                    HStack {
                        if preferenceStore.cpuMenuDisplay == .usagePercentage {
                            MiniSectionView(title: "cpu.system", value: String(format: "%.1f%%", usageCPU.system))
                            Spacer()
                            MiniSectionView(title: "cpu.user", value: String(format: "%.1f%%", usageCPU.user))
                            Spacer()
                            MiniSectionView(title: "cpu.nice", value: String(format: "%.1f%%", usageCPU.nice))
                        }
                        if preferenceStore.cpuMenuDisplay == .loadAverage {
                            MiniSectionView(title: "1 min", value: cpuStore.loadAverage1MinString)
                            Spacer()
                            MiniSectionView(title: "5 min", value: cpuStore.loadAverage5MinString)
                            Spacer()
                            MiniSectionView(title: "15 min", value: cpuStore.loadAverage15MinString)
                        }
                        cpuStore.temp.map { temp in
                            Group {
                                Spacer()
                                MiniSectionView(title: "cpu.temperature", value: SmcControl.shared.formatTemp(temp))
                            }
                        }
                    }
                }
            }
            if !cpuStore.coreUsages.isEmpty {
                SeparatorView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("cpu.cores".localized())
                        .secondaryDisplayText()
                    ForEach(Array(cpuStore.coreUsages.enumerated()), id: \.offset) { index, usage in
                        HStack(spacing: 8) {
                            Text(cpuStore.coreLabels.indices.contains(index) ? cpuStore.coreLabels[index] : "C\(index)")
                                .secondaryDisplayText()
                                .frame(width: 24, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.secondary.opacity(0.2))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.accentColor)
                                        .frame(width: geometry.size.width * CGFloat(min(usage, 100) / 100))
                                }
                            }
                            .frame(height: 6)
                            Text(String(format: "%.0f%%", usage))
                                .displayText()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            }
            if preferenceStore.showCPUTopActivities {
                SeparatorView()
                VStack(spacing: 8) {
                    ForEach(cpuTopStore.cpuTopProcesses) {
                        ProcessRowView(section: "cpu", process: $0)
                    }
                    if !cpuTopStore.cpuDataAvailable {
                        Spacer()
                        Text("cpu.waiting_status_report".localized())
                            .secondaryDisplayText()
                        Spacer()
                    }
                }
                .frame(minWidth: 311)
                .frame(height: 102) // fix size to avoid jitter in menu view
            }
        }
        .menuBlock()
    }
}
