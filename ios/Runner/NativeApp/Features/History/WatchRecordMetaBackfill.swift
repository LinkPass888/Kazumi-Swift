//
//  WatchRecordMetaBackfill.swift
//  Kazumi
//
//  老观看记录的名字和封面是空的，补一次。
//
//  main 那边一条记录存的是整条番剧对象，名字、封面本来就在里面；native 这边
//  是从追番表里现取的（`PlayerScreen.persistWatchProgress`），没追过番就是空串，
//  于是记录留成空壳，列表上只有一个占位框。而且这条记录一旦存下就永远空着——
//  只在「写记录」那处补，等于要求用户把那部番重看一遍（Colo 3566）。
//
//  所以读到的时候也补：发现封面的地址是空的，就按番剧 ID 向 Bangumi 取一次
//  `images.large`，只写回空着的那几项，进度和集数不动。补过之后存在库里，
//  下次打开就有图，不用再取。
//

import Foundation

/// 给缺名字 / 封面的观看记录补一次元数据。
@MainActor
enum WatchRecordMetaBackfill {
    /// 正在取的番剧 ID。列表一刷新就会再调到一次，没这张表同一部番会被连着取好几遍。
    private static var inFlight: Set<Int> = []

    /// 只处理缺东西的记录，其余直接跳过；没有网络或接口失败就不动它，下次再说。
    static func fill(_ records: [WatchRecord], in library: LibraryStore) {
        for record in records {
            let missingName = record.bangumiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let missingImage = record.imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard missingName || missingImage else { continue }
            guard inFlight.insert(record.bangumiID).inserted else { continue }

            Task { @MainActor in
                defer { inFlight.remove(record.bangumiID) }
                guard let item = await BangumiAPI.info(id: record.bangumiID) else { return }
                library.backfillHistoryMeta(
                    bangumiID: record.bangumiID,
                    name: item.displayName,
                    imageURL: item.largeImage
                )
            }
        }
    }
}
