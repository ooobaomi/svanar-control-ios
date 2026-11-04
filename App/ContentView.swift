import SwiftUI
import MediaPlayer
import AVKit

private let mint = Color(red: 0.61, green: 0.90, blue: 0.73)
private let appBackground = Color(red: 0.06, green: 0.09, blue: 0.10)
private let panel = Color(red: 0.11, green: 0.15, blue: 0.16)

struct ContentView: View {
    @EnvironmentObject private var headphones: HeadphoneManager
    @State private var showEQ = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SVANAR").font(.system(size: 42, weight: .light, design: .rounded)).foregroundStyle(mint)
                        Text("CONTROL / iPhone 耳机伴侣").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 10)

                    connectionCard

                    listeningCard

                    equalizerCard

                    audioCard

                    HStack(alignment: .top, spacing: 8) {
                        if headphones.isBusy || headphones.isConnecting { ProgressView().tint(mint) }
                        Text(headphones.status).font(.footnote).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                    Button("打开 App 蓝牙权限设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.font(.footnote)
                    Text("SVANAR Control 1.0 · 非 HIFIMAN 官方应用\n本机蓝牙通信，无账号、无互联网服务。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(20)
            }.background(appBackground).tint(mint)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showEQ) { EQView().environmentObject(headphones).preferredColorScheme(.dark) }
        }.tint(mint)
    }

    private var connectionCard: some View {
        card {
                        Label(headphones.isReady ? "硬件控制已连接" : "连接耳机", systemImage: "earbuds")
                            .font(.title3.weight(.semibold))
                        Text("HIFIMAN SVANAR WIRELESS").font(.caption).foregroundStyle(.secondary)
                        if headphones.isReady {
                            HStack {
                                battery("左耳", headphones.leftBattery)
                                Spacer()
                                battery("右耳", headphones.rightBattery)
                            }.padding(.vertical, 8)
                            Text("设备标识 · \(headphones.identity.suffix(5))")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("刷新状态") { headphones.refresh() }.disabled(headphones.isBusy)
                                Spacer()
                                Button("断开控制", role: .destructive) { headphones.disconnect() }
                            }.padding(.top, 6)
                        } else {
                            Text("先在 iOS 蓝牙设置配对耳机，再扫描并选择对应设备。电脑端 App 请先断开控制连接。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button(action: headphones.scan) {
                                HStack {
                                    if headphones.isScanning || headphones.isConnecting { ProgressView().tint(appBackground) }
                                    Text(headphones.isConnecting ? "连接中" : headphones.isScanning ? "重新扫描" : "扫描耳机")
                                }.frame(maxWidth: .infinity).padding(.vertical, 8)
                            }.buttonStyle(.borderedProminent).disabled(headphones.isConnecting)
                            ForEach(headphones.candidates) { candidate in
                                Button { headphones.connect(candidate) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(candidate.name).font(.subheadline.weight(.medium))
                                            Text("标识尾号 \(candidate.identity.suffix(5)) · \(candidate.rssi) dBm")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                    }.padding(.vertical, 6)
                                }.disabled(headphones.isConnecting)
                            }
                        }
                    }
    }

    private var listeningCard: some View {
        card {
                        HStack {
                            Text("聆听模式").font(.title3.weight(.semibold))
                            Spacer()
                            Text(headphones.mode?.name ?? "未读取").foregroundStyle(mint)
                        }
                        HStack(spacing: 10) {
                            ForEach(ListeningMode.allCases) { mode in
                                Button { headphones.changeMode(mode) } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: mode.symbol).font(.title2)
                                        Text(mode.name).font(.subheadline)
                                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                                        .background(headphones.mode == mode ? mint.opacity(0.18) : appBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                }.disabled(!headphones.isReady || headphones.isBusy)
                            }
                        }
                        Text("双耳佩戴后切换；只有查询回读一致才显示成功。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
    }

    private var equalizerCard: some View {
        card {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("10 段硬件 EQ").font(.title3.weight(.semibold))
                                Text("31 Hz — 16 kHz / 每段 ±10 dB")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(mint)
                        }
                        Button("打开均衡器") { showEQ = true }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
                        Text("参数直接写入耳机，不依赖播放器或手机端音效处理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
    }

    private var audioCard: some View {
        card {
                        HStack {
                            Text("系统音量与路由").font(.title3.weight(.semibold))
                            Spacer()
                            RoutePicker().frame(width: 40, height: 36)
                        }
                        SystemVolume().frame(height: 36)
                        Text("使用 iOS 原生音量与路由控件。音频蓝牙连接由系统管理，与上方 BLE 控制连接独立。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
    }


    private func battery(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { "\($0)%" } ?? "—").font(.title2.monospacedDigit()).foregroundStyle(mint)
        }
    }
}

private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14, content: content)
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(panel).clipShape(RoundedRectangle(cornerRadius: 20))
}

struct EQView: View {
    @EnvironmentObject private var headphones: HeadphoneManager
    @Environment(\.dismiss) private var dismiss
    private let presets: [(String, [Int])] = [
        ("平直", Array(repeating: 0, count: 10)),
        ("低频增强", [3,3,2,1,0,0,0,0,0,0]),
        ("人声清晰", [-2,-1,0,0,1,2,2,1,0,0]),
        ("柔和高频", [0,0,0,0,0,0,-1,-2,-3,-3])
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("耳机内置 EQ").font(.largeTitle.weight(.light)).foregroundStyle(mint)
                    Text("拖动只修改草稿，点击应用后才会写入耳机。预设是通用调音，不是测量校准曲线。")
                        .font(.footnote).foregroundStyle(.secondary)
                    presetsGrid
                    bandsCard.disabled(headphones.isBusy)
                    applyButton
                    secondaryButtons
                    Text(headphones.eqReadback.map { $0 == headphones.draft } == true ? "草稿与最近一次耳机回读一致" : "草稿尚未得到耳机确认")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(headphones.status).font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.background(appBackground)
                .navigationTitle("均衡器").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(mint)
    }

    private var presetsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(presets.indices, id: \.self) { index in
                            Button(presets[index].0) { headphones.draft = presets[index].1 }
                                .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                    }.disabled(headphones.isBusy)
    }

    private var applyButton: some View {
        Button(action: headphones.applyEQ) {
                        HStack {
                            if headphones.isBusy { ProgressView().tint(appBackground) }
                            Text("应用到耳机").fontWeight(.semibold)
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).disabled(!headphones.isReady || headphones.isBusy)
    }

    private var secondaryButtons: some View {
        HStack {
                        Button("重新读取") { headphones.refresh() }.disabled(!headphones.isReady || headphones.isBusy)
                        Spacer()
                        Button("保存自定义") { headphones.saveDraft() }
                        Button("载入") { headphones.loadDraft() }
                    }.buttonStyle(.bordered).disabled(headphones.isBusy)
    }


    private var bandsCard: some View {
        card {
                        ForEach(HeadphoneProtocol.frequencies.indices, id: \.self) { index in
                            VStack(spacing: 3) {
                                HStack {
                                    Text(frequencyLabel(HeadphoneProtocol.frequencies[index])).font(.subheadline.monospacedDigit())
                                    Spacer()
                                    Text(String(format: "%+d dB", headphones.draft[index]))
                                        .font(.subheadline.monospacedDigit()).foregroundStyle(mint)
                                }
                                Slider(value: Binding(get: { Double(headphones.draft[index]) },
                                                      set: { headphones.draft[index] = Int($0.rounded()) }),
                                       in: -10...10, step: 1)
                                    .accessibilityLabel(frequencyLabel(HeadphoneProtocol.frequencies[index]))
                                    .accessibilityValue("\(headphones.draft[index]) 分贝")
                            }
                        }
                    }
    }


    private func frequencyLabel(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }
}

struct SystemVolume: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.tintColor = UIColor(red: 0.61, green: 0.90, blue: 0.73, alpha: 1)
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) { }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor(red: 0.61, green: 0.90, blue: 0.73, alpha: 1)
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}
